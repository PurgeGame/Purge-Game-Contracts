use anchor_lang::prelude::*;

const GAME_STATE_SEED: &[u8] = b"game-state";
const GAME_TREASURY_SEED: &[u8] = b"game-treasury";
const PLAYER_STATE_SEED: &[u8] = b"player";
const MAP_QUEUE_SEED: &[u8] = b"map-mint-queue";
const RNG_REQUEST_SEED: &[u8] = b"rng-request";
const TICKET_PAGE_SEED: &[u8] = b"ticket";

pub const TICKET_PAGE_CAPACITY: usize = 64;
pub const MAP_QUEUE_CAPACITY: usize = 64;

declare_id!("purGGamE1111111111111111111111111111111111111");

#[event]
pub struct MapMintQueued {
    pub player: Pubkey,
    pub trait_id: u16,
    pub level: u32,
    pub queue_len: u64,
}

#[event]
pub struct MapMintDequeued {
    pub player: Pubkey,
    pub trait_id: u16,
    pub level: u32,
    pub queue_len: u64,
}

#[event]
pub struct RngRequested {
    pub slot: u64,
    pub tag: [u8; 8],
}

#[event]
pub struct RngFulfilled {
    pub slot: u64,
    pub word: [u8; 32],
}

#[event]
pub struct TraitTicketAdded {
    pub level: u32,
    pub trait_id: u16,
    pub page_index: u16,
    pub position: u16,
    pub player: Pubkey,
}

#[event]
pub struct TraitTicketCleared {
    pub level: u32,
    pub trait_id: u16,
    pub page_index: u16,
}

#[program]
pub mod purge_game {
    use super::*;

    pub fn initialize_game(ctx: Context<InitializeGame>, args: InitializeGameArgs) -> Result<()> {
        let state = &mut ctx.accounts.game_state;
        state.authority = ctx.accounts.authority.key();
        state.config = GameConfig {
            price_lamports: args.price_lamports,
            price_purge: args.price_purge,
            max_level: args.max_level,
            coin_program: args.coin_program,
            trophy_program: args.trophy_program,
            rng_provider: args.rng_provider,
            jackpots_per_day: args.jackpots_per_day,
            early_purge_threshold: args.early_purge_threshold,
            treasury_bump: *ctx.bumps.get("game_treasury").unwrap(),
        };
        state.level = 1;
        state.phase = GamePhase::Minting;
        state.jackpot_counter = 0;
        state.daily_index = 0;
        state.rng_locked = false;
        state.rng_last_request_slot = 0;
        state.rng_word = [0u8; 32];
        state.prize_pool_lamports = 0;
        state.next_prize_pool_lamports = 0;
        state.carryover_lamports = 0;
        state.last_level_prize_pool = 0;
        state.coin_prize_pool = 0;
        state.map_queue_len = 0;
        state.pending_endgame_cursor = 0;
        state.bump = *ctx.bumps.get("game_state").unwrap();

        let treasury = &mut ctx.accounts.game_treasury;
        treasury.bump = *ctx.bumps.get("game_treasury").unwrap();

        let queue = &mut ctx.accounts.map_mint_queue;
        queue.bump = *ctx.bumps.get("map_mint_queue").unwrap();
        queue.head = 0;
        queue.tail = 0;
        queue.items = [PendingMapMint::default(); MAP_QUEUE_CAPACITY];
        Ok(())
    }

    pub fn mint_nft(ctx: Context<MintNft>, args: MintNftArgs) -> Result<()> {
        // TODO: implement mint flow (SOL/SPL payments, RNG lock handling, ticket accounting).
        if ctx.accounts.game_state.phase != GamePhase::Minting {
            return Err(PurgeError::PhaseMismatch.into());
        }
        let player_state = &mut ctx.accounts.player_state;
        if player_state.bump == 0 {
            player_state.bump = *ctx.bumps.get("player_state").unwrap();
            player_state.owner = ctx.accounts.payer.key();
        }
        player_state.total_mints = player_state
            .total_mints
            .saturating_add(args.quantity as u64);
        player_state.last_level_interaction = ctx.accounts.game_state.level;
        Ok(())
    }

    pub fn purge_tokens(ctx: Context<PurgeTokens>, _args: PurgeTokensArgs) -> Result<()> {
        if ctx.accounts.game_state.phase != GamePhase::PurgeWindow {
            return Err(PurgeError::PhaseMismatch.into());
        }
        // TODO: burn NFTs, adjust trait counts, enqueue jackpots.
        Ok(())
    }

    pub fn advance_level(ctx: Context<AdvanceLevel>, _args: AdvanceLevelArgs) -> Result<()> {
        let state = &mut ctx.accounts.game_state;
        if state.level >= state.config.max_level {
            return Err(PurgeError::MaxLevelReached.into());
        }
        // TODO: snapshot prize pools, rotate phases, emit events.
        state.level = state.level.saturating_add(1);
        state.phase = GamePhase::Maintenance;
        // TODO: execute level transitions, carryover prize pools, and phase updates.
        Ok(())
    }

    pub fn process_jackpot_daily(_ctx: Context<ProcessJackpotDaily>, _args: ProcessJackpotArgs) -> Result<()> {
        // TODO: integrate jackpot logic once PurgeCoin CPI helpers are in place.
        Ok(())
    }

    pub fn process_jackpot_map(_ctx: Context<ProcessJackpotMap>, _args: ProcessJackpotArgs) -> Result<()> {
        // TODO: iterate trait ticket pages and distribute SOL/SPL prizes.
        Ok(())
    }

    pub fn finalize_endgame_step(_ctx: Context<FinalizeEndgameStep>) -> Result<()> {
        // TODO: mirror DEFAULT_PAYOUTS_PER_TX batching semantics from Solidity module.
        Ok(())
    }

    pub fn request_rng(ctx: Context<RequestRng>, args: RequestRngArgs) -> Result<()> {
        let state = &mut ctx.accounts.game_state;
        if state.rng_locked {
            return Err(PurgeError::RngRequestPending.into());
        }
        state.rng_locked = true;
        state.rng_last_request_slot = Clock::get()?.slot;
        // TODO: emit event / call out to VRF CPI.
        let request = &mut ctx.accounts.rng_request;
        request.bump = *ctx.bumps.get("rng_request").unwrap();
        request.slot = state.rng_last_request_slot;
        request.tag = args.tag;
        request.fulfilled = false;
        emit!(RngRequested {
            slot: state.rng_last_request_slot,
            tag: args.tag,
        });
        Ok(())
    }

    pub fn fulfill_rng(ctx: Context<FulfillRng>, rng_word: [u8; 32]) -> Result<()> {
        let state = &mut ctx.accounts.game_state;
        if !state.rng_locked {
            return Err(PurgeError::RngNotLocked.into());
        }
        if ctx.accounts.authority.key() != state.config.rng_provider {
            return Err(PurgeError::Unauthorized.into());
        }
        state.rng_word = rng_word;
        state.rng_locked = false;
        let request = &mut ctx.accounts.rng_request;
        request.fulfilled = true;
        emit!(RngFulfilled {
            slot: request.slot,
            word: rng_word,
        });
        Ok(())
    }

    pub fn configure_game(ctx: Context<ConfigureGame>, args: ConfigureGameArgs) -> Result<()> {
        let state = &mut ctx.accounts.game_state;
        require_keys_eq!(ctx.accounts.authority.key(), state.authority, PurgeError::Unauthorized);

        if let Some(price_lamports) = args.price_lamports {
            state.config.price_lamports = price_lamports;
        }
        if let Some(price_purge) = args.price_purge {
            state.config.price_purge = price_purge;
        }
        if let Some(jackpots_per_day) = args.jackpots_per_day {
            state.config.jackpots_per_day = jackpots_per_day;
        }
        if let Some(early_purge_threshold) = args.early_purge_threshold {
            state.config.early_purge_threshold = early_purge_threshold;
        }
        if let Some(rng_provider) = args.rng_provider {
            state.config.rng_provider = rng_provider;
        }
        Ok(())
    }

    pub fn queue_map_mint(ctx: Context<QueueMapMint>, entry: QueueMapMintArgs) -> Result<()> {
        let state = &mut ctx.accounts.game_state;
        require_keys_eq!(
            ctx.accounts.authority.key(),
            state.authority,
            PurgeError::Unauthorized
        );
        let queue = &mut ctx.accounts.map_mint_queue;
        queue.push(PendingMapMint {
            player: entry.player,
            trait_id: entry.trait_id,
            level: entry.level,
        })?;
        state.map_queue_len = queue.len() as u32;
        emit!(MapMintQueued {
            player: entry.player,
            trait_id: entry.trait_id,
            level: entry.level,
            queue_len: queue.len(),
        });
        Ok(())
    }

    pub fn dequeue_map_mint(ctx: Context<DequeueMapMint>) -> Result<()> {
        let state = &mut ctx.accounts.game_state;
        require_keys_eq!(
            ctx.accounts.authority.key(),
            state.authority,
            PurgeError::Unauthorized
        );
        let queue = &mut ctx.accounts.map_mint_queue;
        let popped = queue.pop()?;
        state.map_queue_len = queue.len() as u32;
        emit!(MapMintDequeued {
            player: popped.player,
            trait_id: popped.trait_id,
            level: popped.level,
            queue_len: queue.len(),
        });
        Ok(())
    }

    pub fn add_trait_ticket(ctx: Context<AddTraitTicket>, args: AddTraitTicketArgs) -> Result<()> {
        let state = &ctx.accounts.game_state;
        require_keys_eq!(
            ctx.accounts.authority.key(),
            state.authority,
            PurgeError::Unauthorized
        );

        let ticket_page = &mut ctx.accounts.ticket_page;
        if ticket_page.bump == 0 {
            ticket_page.bump = *ctx.bumps.get("ticket_page").unwrap();
        }
        ticket_page.ensure_header(args.level, args.trait_id, args.page_index)?;
        let position = ticket_page.push(ctx.accounts.player.key())?;

        emit!(TraitTicketAdded {
            level: ticket_page.level,
            trait_id: ticket_page.trait_id,
            page_index: ticket_page.page_index,
            position,
            player: ctx.accounts.player.key(),
        });
        Ok(())
    }

    pub fn clear_trait_ticket_page(
        ctx: Context<ClearTraitTicketPage>,
        args: ClearTraitTicketPageArgs,
    ) -> Result<()> {
        let state = &ctx.accounts.game_state;
        require_keys_eq!(
            ctx.accounts.authority.key(),
            state.authority,
            PurgeError::Unauthorized
        );

        let ticket_page = &mut ctx.accounts.ticket_page;
        ticket_page.ensure_header(args.level, args.trait_id, args.page_index)?;
        ticket_page.clear();

        emit!(TraitTicketCleared {
            level: args.level,
            trait_id: args.trait_id,
            page_index: args.page_index,
        });
        Ok(())
    }
}

#[derive(Accounts)]
#[instruction(args: InitializeGameArgs)]
pub struct InitializeGame<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    /// CHECK: authority is recorded for future config updates.
    pub authority: UncheckedAccount<'info>,
    #[account(
        init,
        payer = payer,
        space = 8 + GameState::INIT_SPACE,
        seeds = [GAME_STATE_SEED],
        bump
    )]
    pub game_state: Account<'info, GameState>,
    #[account(
        init,
        payer = payer,
        space = 8 + GameTreasury::INIT_SPACE,
        seeds = [GAME_TREASURY_SEED],
        bump
    )]
    pub game_treasury: Account<'info, GameTreasury>,
    #[account(
        init,
        payer = payer,
        space = 8 + PendingMapMintQueue::INIT_SPACE,
        seeds = [MAP_QUEUE_SEED],
        bump
    )]
    pub map_mint_queue: Account<'info, PendingMapMintQueue>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct MintNft<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    #[account(mut, seeds = [GAME_STATE_SEED], bump = game_state.bump)]
    pub game_state: Account<'info, GameState>,
    #[account(mut, seeds = [GAME_TREASURY_SEED], bump = game_treasury.bump)]
    pub game_treasury: Account<'info, GameTreasury>,
    #[account(
        init_if_needed,
        payer = payer,
        space = 8 + PlayerState::INIT_SPACE,
        seeds = [PLAYER_STATE_SEED, payer.key().as_ref()],
        bump
    )]
    pub player_state: Account<'info, PlayerState>,
    pub system_program: Program<'info, System>,
    // TODO: add accounts for NFT mint, metadata, treasury, and PurgeCoin token accounts.
}

#[derive(Accounts)]
pub struct PurgeTokens<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(mut, seeds = [GAME_STATE_SEED], bump = game_state.bump)]
    pub game_state: Account<'info, GameState>,
    #[account(mut, seeds = [GAME_TREASURY_SEED], bump = game_treasury.bump)]
    pub game_treasury: Account<'info, GameTreasury>,
    #[account(
        mut,
        seeds = [PLAYER_STATE_SEED, authority.key().as_ref()],
        bump = player_state.bump
    )]
    pub player_state: Account<'info, PlayerState>,
    // TODO: add NFT accounts, trait ticket PDAs, and SPL treasuries.
}

#[derive(Accounts)]
pub struct AdvanceLevel<'info> {
    #[account(mut, seeds = [GAME_STATE_SEED], bump = game_state.bump)]
    pub game_state: Account<'info, GameState>,
    #[account(mut, seeds = [MAP_QUEUE_SEED], bump = map_mint_queue.bump)]
    pub map_mint_queue: Account<'info, PendingMapMintQueue>,
}

#[derive(Accounts)]
pub struct ProcessJackpotDaily<'info> {
    #[account(mut, seeds = [GAME_STATE_SEED], bump = game_state.bump)]
    pub game_state: Account<'info, GameState>,
    #[account(mut, seeds = [GAME_TREASURY_SEED], bump = game_treasury.bump)]
    pub game_treasury: Account<'info, GameTreasury>,
    // TODO: bring in PurgeCoin CPI accounts, coin treasury, and trait ticket PDAs.
}

#[derive(Accounts)]
pub struct FinalizeEndgameStep<'info> {
    #[account(mut, seeds = [GAME_STATE_SEED], bump = game_state.bump)]
    pub game_state: Account<'info, GameState>,
    // TODO: add participant list PDAs and payout treasury accounts.
}

#[derive(Accounts)]
pub struct ProcessJackpotMap<'info> {
    #[account(mut, seeds = [GAME_STATE_SEED], bump = game_state.bump)]
    pub game_state: Account<'info, GameState>,
    #[account(mut, seeds = [GAME_TREASURY_SEED], bump = game_treasury.bump)]
    pub game_treasury: Account<'info, GameTreasury>,
}

#[derive(Accounts)]
pub struct RequestRng<'info> {
    #[account(mut, seeds = [GAME_STATE_SEED], bump = game_state.bump)]
    pub game_state: Account<'info, GameState>,
    #[account(
        init,
        payer = payer,
        space = 8 + RngRequestState::INIT_SPACE,
        seeds = [RNG_REQUEST_SEED],
        bump
    )]
    pub rng_request: Account<'info, RngRequestState>,
    #[account(mut)]
    pub payer: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct FulfillRng<'info> {
    #[account(mut)]
    pub authority: Signer<'info>,
    #[account(mut, seeds = [GAME_STATE_SEED], bump = game_state.bump)]
    pub game_state: Account<'info, GameState>,
    #[account(mut, seeds = [RNG_REQUEST_SEED], bump = rng_request.bump)]
    pub rng_request: Account<'info, RngRequestState>,
}

#[derive(Accounts)]
pub struct ConfigureGame<'info> {
    pub authority: Signer<'info>,
    #[account(mut, seeds = [GAME_STATE_SEED], bump = game_state.bump)]
    pub game_state: Account<'info, GameState>,
}

#[derive(Accounts)]
pub struct QueueMapMint<'info> {
    pub authority: Signer<'info>,
    #[account(mut, seeds = [GAME_STATE_SEED], bump = game_state.bump)]
    pub game_state: Account<'info, GameState>,
    #[account(mut, seeds = [MAP_QUEUE_SEED], bump = map_mint_queue.bump)]
    pub map_mint_queue: Account<'info, PendingMapMintQueue>,
}

#[derive(Accounts)]
pub struct DequeueMapMint<'info> {
    pub authority: Signer<'info>,
    #[account(mut, seeds = [GAME_STATE_SEED], bump = game_state.bump)]
    pub game_state: Account<'info, GameState>,
    #[account(mut, seeds = [MAP_QUEUE_SEED], bump = map_mint_queue.bump)]
    pub map_mint_queue: Account<'info, PendingMapMintQueue>,
}

#[derive(Accounts)]
#[instruction(args: AddTraitTicketArgs)]
pub struct AddTraitTicket<'info> {
    pub authority: Signer<'info>,
    #[account(mut, seeds = [GAME_STATE_SEED], bump = game_state.bump)]
    pub game_state: Account<'info, GameState>,
    /// CHECK: ticket owner reference added to the page
    pub player: UncheckedAccount<'info>,
    #[account(
        init_if_needed,
        payer = authority,
        space = 8 + TraitTicketPage::INIT_SPACE,
        seeds = [
            TICKET_PAGE_SEED,
            &args.level.to_le_bytes(),
            &args.trait_id.to_le_bytes(),
            &args.page_index.to_le_bytes()
        ],
        bump
    )]
    pub ticket_page: Account<'info, TraitTicketPage>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(args: ClearTraitTicketPageArgs)]
pub struct ClearTraitTicketPage<'info> {
    pub authority: Signer<'info>,
    #[account(mut, seeds = [GAME_STATE_SEED], bump = game_state.bump)]
    pub game_state: Account<'info, GameState>,
    #[account(mut,
        seeds = [
            TICKET_PAGE_SEED,
            &args.level.to_le_bytes(),
            &args.trait_id.to_le_bytes(),
            &args.page_index.to_le_bytes()
        ],
        bump = ticket_page.bump
    )]
    pub ticket_page: Account<'info, TraitTicketPage>,
}

#[account]
pub struct GameState {
    pub authority: Pubkey,
    pub config: GameConfig,
    pub level: u32,
    pub phase: GamePhase,
    pub jackpot_counter: u16,
    pub daily_index: u32,
    pub rng_locked: bool,
    pub rng_last_request_slot: u64,
    pub rng_word: [u8; 32],
    pub prize_pool_lamports: u64,
    pub next_prize_pool_lamports: u64,
    pub carryover_lamports: u64,
    pub last_level_prize_pool: u64,
    pub coin_prize_pool: u64,
    pub map_queue_len: u32,
    pub pending_endgame_cursor: u32,
    pub bump: u8,
}

impl GameState {
    pub const INIT_SPACE: usize = 256;
}

#[account]
pub struct GameTreasury {
    pub bump: u8,
}

impl GameTreasury {
    pub const INIT_SPACE: usize = 1;
}

#[account]
pub struct PlayerState {
    pub owner: Pubkey,
    pub total_mints: u64,
    pub total_purges: u64,
    pub mint_streak: u32,
    pub luckbox_score: u64,
    pub claimable_reward_lamports: u64,
    pub claimable_reward_purge: u64,
    pub last_level_interaction: u32,
    pub bump: u8,
}

impl PlayerState {
    pub const INIT_SPACE: usize = 32 + 8 + 8 + 4 + 8 + 8 + 8 + 4 + 1;
}

#[account]
pub struct PendingMapMintQueue {
    pub head: u64,
    pub tail: u64,
    pub items: [PendingMapMint; MAP_QUEUE_CAPACITY],
    pub bump: u8,
}

impl PendingMapMintQueue {
    pub const INIT_SPACE: usize =
        8 + 8 + (PendingMapMint::INIT_SPACE * MAP_QUEUE_CAPACITY) + 1;

    pub fn len(&self) -> u64 {
        self.tail.saturating_sub(self.head)
    }

    pub fn push(&mut self, entry: PendingMapMint) -> Result<()> {
        if self.len() >= MAP_QUEUE_CAPACITY as u64 {
            return Err(PurgeError::QueueFull.into());
        }
        let slot = (self.tail % MAP_QUEUE_CAPACITY as u64) as usize;
        self.items[slot] = entry;
        self.tail = self.tail.wrapping_add(1);
        Ok(())
    }

    pub fn pop(&mut self) -> Result<PendingMapMint> {
        if self.head == self.tail {
            return Err(PurgeError::QueueEmpty.into());
        }
        let slot = (self.head % MAP_QUEUE_CAPACITY as u64) as usize;
        let entry = self.items[slot];
        self.items[slot] = PendingMapMint::default();
        self.head = self.head.wrapping_add(1);
        Ok(entry)
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Default)]
pub struct PendingMapMint {
    pub player: Pubkey,
    pub trait_id: u16,
    pub level: u32,
}

impl PendingMapMint {
    pub const INIT_SPACE: usize = 32 + 2 + 4;
}

#[account]
pub struct RngRequestState {
    pub slot: u64,
    pub tag: [u8; 8],
    pub fulfilled: bool,
    pub bump: u8,
}

impl RngRequestState {
    pub const INIT_SPACE: usize = 8 + 8 + 1 + 1;
}

#[account]
pub struct TraitTicketPage {
    pub level: u32,
    pub trait_id: u16,
    pub page_index: u16,
    pub count: u16,
    pub seats: [Pubkey; TICKET_PAGE_CAPACITY],
    pub bump: u8,
}

impl TraitTicketPage {
    pub const INIT_SPACE: usize =
        4 + 2 + 2 + 2 + (32 * TICKET_PAGE_CAPACITY) + 1;

    pub fn ensure_header(&mut self, level: u32, trait_id: u16, page_index: u16) -> Result<()> {
        if self.count == 0 {
            self.level = level;
            self.trait_id = trait_id;
            self.page_index = page_index;
            return Ok(());
        }

        if self.level != level || self.trait_id != trait_id || self.page_index != page_index {
            return Err(PurgeError::TicketPageMismatch.into());
        }
        Ok(())
    }

    pub fn push(&mut self, player: Pubkey) -> Result<u16> {
        if self.count as usize >= TICKET_PAGE_CAPACITY {
            return Err(PurgeError::TicketPageFull.into());
        }
        let idx = self.count as usize;
        self.seats[idx] = player;
        self.count = self.count.saturating_add(1);
        Ok(idx as u16)
    }

    pub fn clear(&mut self) {
        self.count = 0;
        self.seats = [Pubkey::default(); TICKET_PAGE_CAPACITY];
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct InitializeGameArgs {
    pub price_lamports: u64,
    pub price_purge: u64,
    pub max_level: u32,
    pub coin_program: Pubkey,
    pub trophy_program: Pubkey,
    pub rng_provider: Pubkey,
    pub jackpots_per_day: u8,
    pub early_purge_threshold: u8,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct MintNftArgs {
    pub quantity: u16,
    pub rng_request: Option<[u8; 32]>,
    pub payment: MintPaymentKind,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct PurgeTokensArgs {
    pub token_ids: Vec<u64>,
    pub use_purge_coin: bool,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct AdvanceLevelArgs {
    pub force: bool,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct ProcessJackpotArgs {
    pub entropy: [u8; 32],
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct RequestRngArgs {
    pub tag: [u8; 8],
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct QueueMapMintArgs {
    pub player: Pubkey,
    pub trait_id: u16,
    pub level: u32,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct AddTraitTicketArgs {
    pub level: u32,
    pub trait_id: u16,
    pub page_index: u16,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct ClearTraitTicketPageArgs {
    pub level: u32,
    pub trait_id: u16,
    pub page_index: u16,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct ConfigureGameArgs {
    pub price_lamports: Option<u64>,
    pub price_purge: Option<u64>,
    pub jackpots_per_day: Option<u8>,
    pub early_purge_threshold: Option<u8>,
    pub rng_provider: Option<Pubkey>,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Default)]
pub struct GameConfig {
    pub price_lamports: u64,
    pub price_purge: u64,
    pub max_level: u32,
    pub coin_program: Pubkey,
    pub trophy_program: Pubkey,
    pub rng_provider: Pubkey,
    pub jackpots_per_day: u8,
    pub early_purge_threshold: u8,
    pub treasury_bump: u8,
}

impl GameConfig {
    pub const INIT_SPACE: usize = 8 + 8 + 4 + 32 + 32 + 32 + 1 + 1 + 1;
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, PartialEq, Eq)]
pub enum GamePhase {
    Minting,
    PurgeWindow,
    Endgame,
    Maintenance,
}

impl Default for GamePhase {
    fn default() -> Self {
        Self::Minting
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub enum MintPaymentKind {
    Sol,
    Purge { amount: u64 },
    Hybrid { sol: u64, purge: u64 },
}

impl Default for MintPaymentKind {
    fn default() -> Self {
        MintPaymentKind::Sol
    }
}

#[error_code]
pub enum PurgeError {
    #[msg("Unauthorized")]
    Unauthorized,
    #[msg("Action not allowed in current phase")]
    PhaseMismatch,
    #[msg("RNG request already pending")]
    RngRequestPending,
    #[msg("RNG not locked")]
    RngNotLocked,
    #[msg("Maximum level reached")]
    MaxLevelReached,
    #[msg("Map mint queue is full")]
    QueueFull,
    #[msg("Map mint queue is empty")]
    QueueEmpty,
    #[msg("Trait ticket page is full")]
    TicketPageFull,
    #[msg("Trait ticket page header mismatch")]
    TicketPageMismatch,
}
