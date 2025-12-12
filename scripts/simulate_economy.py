import math

def simulate():
    # Constants
    BOND_BPS_MAP = 5000     # 50%
    BOND_BPS_DAILY = 2000   # 20%
    BOND_BPS_BIG = 5000     # 50% (Assumed for BAF/Decimator)
    VAULT_SPLIT = 0.30      # 30% of bond spend goes to vault
    REWARD_RETURN = 0.20    # 20% of bond spend returns to reward pool
    
    # State
    reward_pool = 0.0
    current_prize_pool = 0.0
    next_prize_pool = 0.0
    
    # Vault Accumulator
    vault_total = 0.0
    
    # Data collector
    data = []

    # Daily Jackpot BPS schedule (0-9)
    daily_bps = [610, 677, 746, 813, 881, 949, 1017, 1085, 1153, 1225]

    for lvl in range(1, 101):
        # 1. Growth Phase (Mints)
        mints = 150.0 * (1.05 ** (lvl - 1))
        next_prize_pool += mints
        
        # 2. End of Purchase Phase (Map Jackpot Calculation)
        current_prize_pool += next_prize_pool
        next_prize_pool = 0.0
        
        total_wei = reward_pool + current_prize_pool
        
        # _mapRewardPoolPercent
        if lvl <= 4:
            increments = lvl - 1
            base_times_2 = (8 + increments * 8) * 2
        elif lvl <= 79:
            base_times_2 = 64 + (lvl - 4)
        else:
            base_times_2 = 130 # Approximation
            
        base_times_2 += 20 
        if base_times_2 > 196: base_times_2 = 196
        
        reward_pool_allocation = (total_wei * base_times_2) / 200.0
        reward_pool = reward_pool_allocation
        
        jackpot_base = total_wei - reward_pool
        
        map_pct = 0.30
        if lvl % 20 == 16: map_pct = 0.40
        
        map_wei = jackpot_base * map_pct
        main_wei = jackpot_base - map_wei
        
        current_prize_pool = main_wei
        
        # Map Jackpot Payout
        bond_spend_map = map_wei * (BOND_BPS_MAP / 10000.0)
        vault_cut_map = bond_spend_map * VAULT_SPLIT
        reward_return_map = bond_spend_map * REWARD_RETURN
        
        vault_total += vault_cut_map
        reward_pool += reward_return_map
        map_payout_net = map_wei

        # 3. Early Jackpots (High count: 11 runs)
        # ASSUMPTION: Boost is ARMED (200 bps) because Growth vs Small Previous Pot triggers threshold.
        early_jackpot_total = 0.0
        
        for _ in range(11):
            # Scale Bps logic
            cycle = (lvl - 1) % 100
            discount = (cycle * 5000) / 99
            scale = (10000 - discount) / 10000.0
            if scale < 0.5: scale = 0.5
            
            pool_bps = 200.0 # BOOSTED (2%)
            slice_amount = (reward_pool * pool_bps / 10000.0) * scale
            
            bond_spend_early = slice_amount * (BOND_BPS_DAILY / 10000.0)
            vault_cut_early = bond_spend_early * VAULT_SPLIT
            reward_return_early = bond_spend_early * REWARD_RETURN
            
            vault_total += vault_cut_early
            reward_pool -= slice_amount
            reward_pool += reward_return_early
            early_jackpot_total += slice_amount

        # 4. Normal Jackpots (10 runs)
        normal_jackpot_total = 0.0
        for i in range(10):
            bps = daily_bps[i]
            daily_amount = (current_prize_pool * bps) / 10000.0
            
            bond_spend_daily = daily_amount * (BOND_BPS_DAILY / 10000.0)
            vault_cut_daily = bond_spend_daily * VAULT_SPLIT
            reward_return_daily = bond_spend_daily * REWARD_RETURN
            
            vault_total += vault_cut_daily
            reward_pool += reward_return_daily
            current_prize_pool -= daily_amount
            normal_jackpot_total += daily_amount

        # 5. Level End: BAF / Decimator
        if lvl % 10 == 0:
            pct = 0.25 if lvl == 50 else 0.10
            baf_amount = reward_pool * pct
            
            bond_spend_baf = baf_amount * (BOND_BPS_BIG / 10000.0)
            vault_cut_baf = bond_spend_baf * VAULT_SPLIT
            reward_return_baf = bond_spend_baf * REWARD_RETURN
            
            vault_total += vault_cut_baf
            reward_pool -= baf_amount
            reward_pool += reward_return_baf
            
        if lvl % 10 == 5 and lvl >= 15 and lvl != 95:
            dec_amount = reward_pool * 0.15
            
            bond_spend_dec = dec_amount * (BOND_BPS_BIG / 10000.0)
            vault_cut_dec = bond_spend_dec * VAULT_SPLIT
            reward_return_dec = bond_spend_dec * REWARD_RETURN
            
            vault_total += vault_cut_dec
            reward_pool -= dec_amount
            reward_pool += reward_return_dec
            
        # Exterminator Payout (assume 30% avg share of remainder)
        exterminator_win = current_prize_pool * 0.30
        current_prize_pool = 0.0 # Standard clear

        # Capture Data every 5 levels
        if lvl % 5 == 0:
            data.append({
                "Level": lvl,
                "RewardPool": reward_pool,
                "NextPool_Input": mints,
                "EndOfPurchase_MapJackpot": map_payout_net,
                "Early_Jackpots": early_jackpot_total,
                "Normal_Jackpots": normal_jackpot_total,
                "Vault_Revenue_Cumulative": vault_total
            })

    # Print Table
    print(f"{'Lvl':<5} | {'RewardPool':<12} | {'NextPool(In)':<12} | {'MapJackpot':<12} | {'EarlyJackpot':<12} | {'NormalJackpot':<13} | {'Vault(Cum)':<12}")
    print("-" * 95)
    for row in data:
        print(f"{row['Level']:<5} | {row['RewardPool']:<12.2f} | {row['NextPool_Input']:<12.2f} | {row['EndOfPurchase_MapJackpot']:<12.2f} | {row['Early_Jackpots']:<12.2f} | {row['Normal_Jackpots']:<13.2f} | {row['Vault_Revenue_Cumulative']:<12.2f}")

simulate()