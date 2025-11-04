use anchor_lang::prelude::*;

const TROPHY_STATE_SEED: &[u8] = b"trophies";
const TROPHY_VAULT_SEED: &[u8] = b"trophy-vault";
const MAP_REWARD_QUEUE_SEED: &[u8] = b"map-reward-queue";
const STAKE_SAMPLE_SEED: &[u8] = b"stake-sample";

pub const MAP_REWARD_QUEUE_CAPACITY: usize = 64;

declare_id!("purGTroph111111111111111111111111111111111");

#[program]
pub mod purge_trophies {
    use super::*;

    pub fn initialize(ctx: Context<Initialize>, args: InitializeArgs) -> Result<()> {
        let state = &mut ctx.accounts.state;
        state.authority = ctx.accounts.authority.key();
        state.bump = *ctx.bumps.get("state").unwrap();
        state.map_reward_basis_points = args.map_reward_basis_points;
        state.map_reward_minimum = args.map_reward_minimum;
        state.purge_coin_program = args.purge_coin_program;
        state.purge_game_program = args.purge_game_program;
        state.game_authority = args.game_authority;
        state.vault_bump = *ctx.bumps.get("trophy_vault").unwrap();
        state.sample_bump = *ctx.bumps.get("stake_sample").unwrap();

        let vault = &mut ctx.accounts.trophy_vault;
        vault.bump = *ctx.bumps.get("trophy_vault").unwrap();
        vault.pending_amount = 0;
        vault.last_level_paid = 0;

        let queue = &mut ctx.accounts.map_reward_queue;
        queue.bump = *ctx.bumps.get("map_reward_queue").unwrap();
        queue.head = 0;
        queue.tail = 0;
        queue.entries = [MapRewardEntry::default(); MAP_REWARD_QUEUE_CAPACITY];

        let sample = &mut ctx.accounts.stake_sample;
        sample.bump = *ctx.bumps.get("stake_sample").unwrap();
        sample.last_roll = 0;
        Ok(())
    }

    pub fn award_trophy(ctx: Context<AwardTrophy>, args: AwardTrophyArgs) -> Result<()> {
        require_keys_eq!(
            ctx.accounts.authority.key(),
            ctx.accounts.state.authority,
            TrophyError::Unauthorized
        );
        let vault = &mut ctx.accounts.trophy_vault;
        vault.pending_amount = vault.pending_amount.saturating_add(args.deferred_lamports);
        // TODO: mint trophy NFT or update metadata using args.kind/data.
        // TODO: mint trophy NFTs or update compressed metadata structures.
        Ok(())
    }

    pub fn process_end_level(ctx: Context<ProcessEndLevel>, args: ProcessEndLevelArgs) -> Result<()> {
        let state = &mut ctx.accounts.state;
        if args.level <= ctx.accounts.trophy_vault.last_level_paid {
            return Err(TrophyError::LevelAlreadySettled.into());
        }
        // TODO: iterate map reward queue, settle payouts, interact with PurgeCoin CPI.
        ctx.accounts.trophy_vault.last_level_paid = args.level;
        state.last_level_processed = args.level;
        // TODO: mirror trophies/endgame accounting and SOL distribution.
        Ok(())
    }

    pub fn enqueue_map_reward(ctx: Context<EnqueueMapReward>, entry: MapRewardArgs) -> Result<()> {
        let state = &ctx.accounts.state;
        require_keys_eq!(ctx.accounts.authority.key(), state.game_authority, TrophyError::Unauthorized);
        let queue = &mut ctx.accounts.map_reward_queue;
        let next_tail = queue.tail.wrapping_add(1);
        if next_tail - queue.head > MAP_REWARD_QUEUE_CAPACITY as u64 {
            return Err(TrophyError::QueueFull.into());
        }
        let slot = (queue.tail % MAP_REWARD_QUEUE_CAPACITY as u64) as usize;
        queue.entries[slot] = MapRewardEntry {
            player: entry.player,
            trait_id: entry.trait_id,
            level: entry.level,
            amount_lamports: entry.amount_lamports,
        };
        queue.tail = next_tail;
        Ok(())
    }

    pub fn pop_map_reward(ctx: Context<PopMapReward>) -> Result<()> {
        let queue = &mut ctx.accounts.map_reward_queue;
        if queue.head == queue.tail {
            return Err(TrophyError::QueueEmpty.into());
        }
        let slot = (queue.head % MAP_REWARD_QUEUE_CAPACITY as u64) as usize;
        queue.entries[slot] = MapRewardEntry::default();
        queue.head = queue.head.wrapping_add(1);
        Ok(())
    }
}

#[derive(Accounts)]
#[instruction(args: InitializeArgs)]
pub struct Initialize<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    /// CHECK: recorded as trusted authority.
    pub authority: UncheckedAccount<'info>,
    #[account(
        init,
        payer = payer,
        space = 8 + TrophyState::INIT_SPACE,
        seeds = [TROPHY_STATE_SEED],
        bump
    )]
    pub state: Account<'info, TrophyState>,
    #[account(
        init,
        payer = payer,
        space = 8 + TrophyVault::INIT_SPACE,
        seeds = [TROPHY_VAULT_SEED],
        bump
    )]
    pub trophy_vault: Account<'info, TrophyVault>,
    #[account(
        init,
        payer = payer,
        space = 8 + MapRewardQueueAccount::INIT_SPACE,
        seeds = [MAP_REWARD_QUEUE_SEED],
        bump
    )]
    pub map_reward_queue: Account<'info, MapRewardQueueAccount>,
    #[account(
        init,
        payer = payer,
        space = 8 + StakeSampleState::INIT_SPACE,
        seeds = [STAKE_SAMPLE_SEED],
        bump
    )]
    pub stake_sample: Account<'info, StakeSampleState>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct AwardTrophy<'info> {
    pub authority: Signer<'info>,
    #[account(mut, seeds = [TROPHY_STATE_SEED], bump = state.bump)]
    pub state: Account<'info, TrophyState>,
    #[account(mut, seeds = [TROPHY_VAULT_SEED], bump = trophy_vault.bump)]
    pub trophy_vault: Account<'info, TrophyVault>,
    // TODO: add NFT mint accounts and payout PDAs.
}

#[derive(Accounts)]
pub struct ProcessEndLevel<'info> {
    #[account(mut, seeds = [TROPHY_STATE_SEED], bump = state.bump)]
    pub state: Account<'info, TrophyState>,
    #[account(mut, seeds = [TROPHY_VAULT_SEED], bump = trophy_vault.bump)]
    pub trophy_vault: Account<'info, TrophyVault>,
    #[account(mut, seeds = [MAP_REWARD_QUEUE_SEED], bump = map_reward_queue.bump)]
    pub map_reward_queue: Account<'info, MapRewardQueueAccount>,
    // TODO: include SOL pools, PurgeCoin CPI accounts, and map payout queues.
}

#[derive(Accounts)]
pub struct EnqueueMapReward<'info> {
    pub authority: Signer<'info>,
    #[account(seeds = [TROPHY_STATE_SEED], bump = state.bump)]
    pub state: Account<'info, TrophyState>,
    #[account(mut, seeds = [MAP_REWARD_QUEUE_SEED], bump = map_reward_queue.bump)]
    pub map_reward_queue: Account<'info, MapRewardQueueAccount>,
}

#[derive(Accounts)]
pub struct PopMapReward<'info> {
    #[account(mut, seeds = [MAP_REWARD_QUEUE_SEED], bump = map_reward_queue.bump)]
    pub map_reward_queue: Account<'info, MapRewardQueueAccount>,
}

#[account]
pub struct TrophyState {
    pub authority: Pubkey,
    pub map_reward_basis_points: u16,
    pub map_reward_minimum: u64,
    pub purge_coin_program: Pubkey,
    pub purge_game_program: Pubkey,
    pub game_authority: Pubkey,
    pub last_level_processed: u32,
    pub vault_bump: u8,
    pub sample_bump: u8,
    pub bump: u8,
}

impl TrophyState {
    pub const INIT_SPACE: usize = 32 + 2 + 8 + 32 + 32 + 32 + 4 + 1 + 1 + 1;
}

#[account]
pub struct TrophyVault {
    pub pending_amount: u64,
    pub last_level_paid: u32,
    pub bump: u8,
}

impl TrophyVault {
    pub const INIT_SPACE: usize = 8 + 4 + 1;
}

#[account]
pub struct MapRewardQueueAccount {
    pub head: u64,
    pub tail: u64,
    pub entries: [MapRewardEntry; MAP_REWARD_QUEUE_CAPACITY],
    pub bump: u8,
}

impl MapRewardQueueAccount {
    pub const INIT_SPACE: usize =
        8 + 8 + (MapRewardEntry::INIT_SPACE * MAP_REWARD_QUEUE_CAPACITY) + 1;
}

#[account]
pub struct StakeSampleState {
    pub last_roll: u64,
    pub bump: u8,
}

impl StakeSampleState {
    pub const INIT_SPACE: usize = 8 + 1;
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Default)]
pub struct MapRewardEntry {
    pub player: Pubkey,
    pub trait_id: u16,
    pub level: u32,
    pub amount_lamports: u64,
}

impl MapRewardEntry {
    pub const INIT_SPACE: usize = 32 + 2 + 4 + 8;
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct InitializeArgs {
    pub map_reward_basis_points: u16,
    pub map_reward_minimum: u64,
    pub purge_coin_program: Pubkey,
    pub purge_game_program: Pubkey,
    pub game_authority: Pubkey,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct AwardTrophyArgs {
    pub level: u32,
    pub kind: u8,
    pub data: u128,
    pub deferred_lamports: u64,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct ProcessEndLevelArgs {
    pub level: u32,
    pub carryover_lamports: u64,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct MapRewardArgs {
    pub player: Pubkey,
    pub trait_id: u16,
    pub level: u32,
    pub amount_lamports: u64,
}

#[error_code]
pub enum TrophyError {
    #[msg("Unauthorized")]
    Unauthorized,
    #[msg("Map reward queue is full")]
    QueueFull,
    #[msg("Map reward queue is empty")]
    QueueEmpty,
    #[msg("Level already settled")]
    LevelAlreadySettled,
}
