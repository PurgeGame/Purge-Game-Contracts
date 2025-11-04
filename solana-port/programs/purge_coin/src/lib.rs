use anchor_lang::prelude::*;

const COIN_STATE_SEED: &[u8] = b"purge-coin";
const COIN_TREASURY_SEED: &[u8] = b"coin-treasury";
const BOUNTY_VAULT_SEED: &[u8] = b"bounty";
const STAKE_STATE_SEED: &[u8] = b"stake";
const AFFILIATE_STATE_SEED: &[u8] = b"affiliate";
const BET_STATE_SEED: &[u8] = b"bet";
const JACKPOT_RESOLVER_SEED: &[u8] = b"jackpot-resolver";

declare_id!("purGCoin111111111111111111111111111111111111");

#[event]
pub struct BetPlaced {
    pub player: Pubkey,
    pub bet_id: u64,
    pub amount: u64,
    pub risk: u8,
}

#[event]
pub struct BetSettled {
    pub player: Pubkey,
    pub bet_id: u64,
    pub result: bool,
    pub payout: u64,
}

#[event]
pub struct BurnRecorded {
    pub player: Pubkey,
    pub amount: u64,
}

#[event]
pub struct AffiliateRewarded {
    pub code_seed: Pubkey,
    pub amount: u64,
}

#[event]
pub struct AffiliateClaimed {
    pub code_seed: Pubkey,
    pub receiver: Pubkey,
    pub amount: u64,
}

#[program]
pub mod purge_coin {
    use super::*;

    pub fn initialize(ctx: Context<Initialize>, args: InitializeArgs) -> Result<()> {
        let state = &mut ctx.accounts.state;
        state.authority = ctx.accounts.authority.key();
        state.mint = ctx.accounts.purge_mint.key();
        state.bump = *ctx.bumps.get("state").unwrap();
        state.min_bet = args.min_bet;
        state.min_burn = args.min_burn;
        state.house_edge_bps = args.house_edge_bps;
        state.burn_tax_bps = args.burn_tax_bps;
        state.treasury_bump = *ctx.bumps.get("coin_treasury").unwrap();
        state.bounty_bump = *ctx.bumps.get("bounty_vault").unwrap();
        state.total_burned = 0;
        state.total_bets = 0;
        state.jackpot_pool_purge = 0;
        state.jackpot_pool_sol = 0;

        ctx.accounts.coin_treasury.bump = *ctx.bumps.get("coin_treasury").unwrap();
        ctx.accounts.bounty_vault.bump = *ctx.bumps.get("bounty_vault").unwrap();
        Ok(())
    }

    pub fn place_bet(ctx: Context<PlaceBet>, args: PlaceBetArgs) -> Result<()> {
        let state = &mut ctx.accounts.state;
        if args.amount < state.min_bet {
            return Err(PurgeCoinError::BelowMinimumBet.into());
        }

        let bet = &mut ctx.accounts.bet;
        bet.bump = *ctx.bumps.get("bet").unwrap();
        bet.player = ctx.accounts.player.key();
        bet.amount = args.amount;
        bet.target_level = args.target_level;
        bet.risk = args.risk;
        bet.bet_id = args.bet_id;
        bet.slot_placed = Clock::get()?.slot;
        bet.resolved = false;

        state.total_bets = state.total_bets.saturating_add(1);
        // TODO: transfer PURGE from player into treasury via CPI.

        let stake_state = &mut ctx.accounts.stake_state;
        if stake_state.bump == 0 {
            stake_state.bump = *ctx.bumps.get("stake_state").unwrap();
            stake_state.owner = ctx.accounts.player.key();
        }
        emit!(BetPlaced {
            player: bet.player,
            bet_id: bet.bet_id,
            amount: bet.amount,
            risk: bet.risk,
        });
        Ok(())
    }

    pub fn settle_bet(ctx: Context<SettleBet>, result: bool, payout: u64) -> Result<()> {
        let state = &mut ctx.accounts.state;
        let bet = &mut ctx.accounts.bet;
        if bet.resolved {
            return Err(PurgeCoinError::BetAlreadyResolved.into());
        }
        bet.resolved = true;
        bet.result = Some(result);
        bet.slot_resolved = Some(Clock::get()?.slot);

        if result {
            // TODO: transfer winnings from treasury to player.
            state.jackpot_pool_purge = state.jackpot_pool_purge.saturating_sub(payout);
        } else {
            state.jackpot_pool_purge = state.jackpot_pool_purge.saturating_add(bet.amount);
        }
        emit!(BetSettled {
            player: bet.player,
            bet_id: bet.bet_id,
            result,
            payout,
        });
        Ok(())
    }

    pub fn record_burn(ctx: Context<RecordBurn>, amount: u64) -> Result<()> {
        let state = &mut ctx.accounts.state;
        if amount < state.min_burn {
            return Err(PurgeCoinError::BelowMinimumBurn.into());
        }
        state.total_burned = state.total_burned.saturating_add(amount);
        // TODO: burn PURGE tokens via CPI and adjust bounty pool.
        emit!(BurnRecorded {
            player: ctx.accounts.player.key(),
            amount,
        });
        Ok(())
    }

    pub fn award_affiliate(ctx: Context<AwardAffiliate>, amount: u64) -> Result<()> {
        require_keys_eq!(
            ctx.accounts.authority.key(),
            ctx.accounts.state.authority,
            PurgeCoinError::Unauthorized
        );
        let affiliate = &mut ctx.accounts.affiliate_state;
        if affiliate.bump == 0 {
            affiliate.bump = *ctx.bumps.get("affiliate_state").unwrap();
            affiliate.code_seed = ctx.accounts.code_seed.key();
        }
        affiliate.total_earned = affiliate.total_earned.saturating_add(amount);
        affiliate.pending_claim = affiliate.pending_claim.saturating_add(amount);
        affiliate.last_level = ctx.accounts.state.last_level_synced;
        // TODO: move PURGE from treasury to pending payout account.
        emit!(AffiliateRewarded {
            code_seed: affiliate.code_seed,
            amount,
        });
        Ok(())
    }

    pub fn configure_coin(ctx: Context<ConfigureCoin>, args: ConfigureCoinArgs) -> Result<()> {
        let state = &mut ctx.accounts.state;
        require_keys_eq!(ctx.accounts.authority.key(), state.authority, PurgeCoinError::Unauthorized);
        if let Some(min_bet) = args.min_bet {
            state.min_bet = min_bet;
        }
        if let Some(min_burn) = args.min_burn {
            state.min_burn = min_burn;
        }
        if let Some(house_edge_bps) = args.house_edge_bps {
            state.house_edge_bps = house_edge_bps;
        }
        if let Some(burn_tax_bps) = args.burn_tax_bps {
            state.burn_tax_bps = burn_tax_bps;
        }
        Ok(())
    }

    pub fn sync_jackpot(_ctx: Context<SyncJackpot>, _amount: u64) -> Result<()> {
        // TODO: invoked by PurgeGame to allocate jackpot balances.
        Ok(())
    }
    
    pub fn claim_affiliate(ctx: Context<ClaimAffiliate>, amount: u64) -> Result<()> {
        let state = &ctx.accounts.state;
        require_keys_eq!(
            ctx.accounts.receiver.key(),
            state.authority,
            PurgeCoinError::Unauthorized
        );
        let affiliate = &mut ctx.accounts.affiliate_state;
        if amount > affiliate.pending_claim {
            return Err(PurgeCoinError::PayoutExceeded.into());
        }
        affiliate.pending_claim = affiliate.pending_claim.saturating_sub(amount);
        affiliate.last_claim_slot = Clock::get()?.slot;
        // TODO: transfer PURGE from treasury to receiver.
        emit!(AffiliateClaimed {
            code_seed: affiliate.code_seed,
            receiver: ctx.accounts.receiver.key(),
            amount,
        });
        Ok(())
    }
}

#[derive(Accounts)]
#[instruction(args: InitializeArgs)]
pub struct Initialize<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    /// CHECK: authority stored for future config updates.
    pub authority: UncheckedAccount<'info>,
    #[account(
        init,
        payer = payer,
        space = 8 + PurgeCoinState::INIT_SPACE,
        seeds = [COIN_STATE_SEED],
        bump
    )]
    pub state: Account<'info, PurgeCoinState>,
    /// CHECK: placeholder until SPL mint wiring is completed.
    pub purge_mint: UncheckedAccount<'info>,
    #[account(
        init,
        payer = payer,
        space = 8 + CoinTreasury::INIT_SPACE,
        seeds = [COIN_TREASURY_SEED],
        bump
    )]
    pub coin_treasury: Account<'info, CoinTreasury>,
    #[account(
        init,
        payer = payer,
        space = 8 + BountyVault::INIT_SPACE,
        seeds = [BOUNTY_VAULT_SEED],
        bump
    )]
    pub bounty_vault: Account<'info, BountyVault>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
#[instruction(args: PlaceBetArgs)]
pub struct PlaceBet<'info> {
    #[account(mut)]
    pub player: Signer<'info>,
    #[account(mut, seeds = [COIN_STATE_SEED], bump = state.bump)]
    pub state: Account<'info, PurgeCoinState>,
    #[account(
        init,
        payer = player,
        space = 8 + BetAccount::INIT_SPACE,
        seeds = [BET_STATE_SEED, player.key().as_ref(), &args.bet_id.to_le_bytes()],
        bump
    )]
    pub bet: Account<'info, BetAccount>,
    #[account(
        init_if_needed,
        payer = player,
        space = 8 + StakeState::INIT_SPACE,
        seeds = [STAKE_STATE_SEED, player.key().as_ref()],
        bump
    )]
    pub stake_state: Account<'info, StakeState>,
    pub system_program: Program<'info, System>,
    // TODO: add token accounts for PURGE transfer.
}

#[derive(Accounts)]
pub struct SettleBet<'info> {
    #[account(mut, seeds = [COIN_STATE_SEED], bump = state.bump)]
    pub state: Account<'info, PurgeCoinState>,
    #[account(mut, seeds = [BET_STATE_SEED, bet.player.as_ref(), &bet.bet_id.to_le_bytes()], bump = bet.bump)]
    pub bet: Account<'info, BetAccount>,
    #[account(mut, seeds = [COIN_TREASURY_SEED], bump = coin_treasury.bump)]
    pub coin_treasury: Account<'info, CoinTreasury>,
    /// CHECK: Verified in caller context.
    pub resolver_program: UncheckedAccount<'info>,
}

#[derive(Accounts)]
pub struct AwardAffiliate<'info> {
    #[account(mut, seeds = [COIN_STATE_SEED], bump = state.bump)]
    pub state: Account<'info, PurgeCoinState>,
    /// CHECK: hashed affiliate code seed (off-chain validated).
    pub code_seed: UncheckedAccount<'info>,
    #[account(
        init_if_needed,
        payer = authority,
        space = 8 + AffiliateState::INIT_SPACE,
        seeds = [AFFILIATE_STATE_SEED, code_seed.key().as_ref()],
        bump
    )]
    pub affiliate_state: Account<'info, AffiliateState>,
    #[account(mut)]
    pub authority: Signer<'info>,
    pub system_program: Program<'info, System>,
    // TODO: include payout token accounts.
}

#[derive(Accounts)]
pub struct RecordBurn<'info> {
    #[account(mut, seeds = [COIN_STATE_SEED], bump = state.bump)]
    pub state: Account<'info, PurgeCoinState>,
    #[account(mut, seeds = [COIN_TREASURY_SEED], bump = coin_treasury.bump)]
    pub coin_treasury: Account<'info, CoinTreasury>,
    #[account(mut)]
    pub player: Signer<'info>,
    // TODO: include token accounts for burn CPI.
}

#[derive(Accounts)]
pub struct ConfigureCoin<'info> {
    pub authority: Signer<'info>,
    #[account(mut, seeds = [COIN_STATE_SEED], bump = state.bump)]
    pub state: Account<'info, PurgeCoinState>,
}

#[derive(Accounts)]
pub struct SyncJackpot<'info> {
    #[account(mut, seeds = [COIN_STATE_SEED], bump = state.bump)]
    pub state: Account<'info, PurgeCoinState>,
    #[account(mut, seeds = [COIN_TREASURY_SEED], bump = coin_treasury.bump)]
    pub coin_treasury: Account<'info, CoinTreasury>,
}

#[derive(Accounts)]
pub struct ClaimAffiliate<'info> {
    #[account(mut, seeds = [COIN_STATE_SEED], bump = state.bump)]
    pub state: Account<'info, PurgeCoinState>,
    /// CHECK: hashed affiliate code seed (off-chain validated).
    pub code_seed: UncheckedAccount<'info>,
    #[account(
        mut,
        seeds = [AFFILIATE_STATE_SEED, code_seed.key().as_ref()],
        bump = affiliate_state.bump
    )]
    pub affiliate_state: Account<'info, AffiliateState>,
    #[account(mut)]
    pub receiver: Signer<'info>,
    // TODO: include payout token accounts.
}

#[account]
pub struct PurgeCoinState {
    pub authority: Pubkey,
    pub mint: Pubkey,
    pub min_bet: u64,
    pub min_burn: u64,
    pub house_edge_bps: u16,
    pub burn_tax_bps: u16,
    pub total_burned: u64,
    pub total_bets: u64,
    pub jackpot_pool_purge: u64,
    pub jackpot_pool_sol: u64,
    pub last_level_synced: u32,
    pub treasury_bump: u8,
    pub bounty_bump: u8,
    pub bump: u8,
}

impl PurgeCoinState {
    pub const INIT_SPACE: usize =
        32 + 32 + 8 + 8 + 2 + 2 + 8 + 8 + 8 + 8 + 4 + 1 + 1 + 1;
}

#[account]
pub struct CoinTreasury {
    pub bump: u8,
}

impl CoinTreasury {
    pub const INIT_SPACE: usize = 1;
}

#[account]
pub struct BountyVault {
    pub bump: u8,
}

impl BountyVault {
    pub const INIT_SPACE: usize = 1;
}

#[account]
pub struct StakeState {
    pub owner: Pubkey,
    pub lanes: [StakeLane; 3],
    pub bump: u8,
}

impl StakeState {
    pub const INIT_SPACE: usize = 32 + (StakeLane::INIT_SPACE * 3) + 1;
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Default)]
pub struct StakeLane {
    pub risk: u8,
    pub principal: u64,
    pub target_level: u32,
}

impl StakeLane {
    pub const INIT_SPACE: usize = 1 + 8 + 4;
}

#[account]
pub struct AffiliateState {
    pub code_seed: Pubkey,
    pub total_earned: u64,
    pub pending_claim: u64,
    pub pending_claim_lamports: u64,
    pub last_level: u32,
    pub last_claim_slot: u64,
    pub bump: u8,
}

impl AffiliateState {
    pub const INIT_SPACE: usize = 32 + 8 + 8 + 8 + 4 + 8 + 1;
}

#[account]
pub struct BetAccount {
    pub player: Pubkey,
    pub amount: u64,
    pub target_level: u32,
    pub risk: u8,
    pub resolved: bool,
    pub bet_id: u64,
    pub result: Option<bool>,
    pub slot_placed: u64,
    pub slot_resolved: Option<u64>,
    pub bump: u8,
}

impl BetAccount {
    pub const INIT_SPACE: usize = 74;
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct InitializeArgs {
    pub min_bet: u64,
    pub min_burn: u64,
    pub house_edge_bps: u16,
    pub burn_tax_bps: u16,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct PlaceBetArgs {
    pub amount: u64,
    pub target_level: u32,
    pub risk: u8,
    pub bet_id: u64,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Default)]
pub struct ConfigureCoinArgs {
    pub min_bet: Option<u64>,
    pub min_burn: Option<u64>,
    pub house_edge_bps: Option<u16>,
    pub burn_tax_bps: Option<u16>,
}

#[error_code]
pub enum PurgeCoinError {
    #[msg("Unauthorized")]
    Unauthorized,
    #[msg("Bet amount below minimum")]
    BelowMinimumBet,
    #[msg("Burn amount below minimum")]
    BelowMinimumBurn,
    #[msg("Bet already resolved")]
    BetAlreadyResolved,
    #[msg("Requested payout exceeds pending balance")]
    PayoutExceeded,
}
