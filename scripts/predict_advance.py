import sys
import os
import json
from web3 import Web3
from eth_utils import keccak, to_checksum_address

# --- Configuration ---
# You can override these via environment variables or CLI args if extended
RPC_URL = os.getenv("RPC_URL", "http://localhost:8545") 
CONTRACT_ADDRESS = os.getenv("GAME_ADDRESS") # Required

# --- Minimal ABI ---
# We only need getters for public state variables. 
# Storage slots are accessed directly for internal vars.
ABI = [
    {"inputs": [], "name": "level", "outputs": [{"internalType": "uint24", "name": "", "type": "uint24"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "gameState", "outputs": [{"internalType": "uint8", "name": "", "type": "uint8"}], "stateMutability": "view", "type": "function"},
    {"inputs": [], "name": "currentPrizePool", "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}], "stateMutability": "view", "type": "function"}, # Internal but sometimes getter exists? No, internal. We'll use getStorage.
    {"inputs": [], "name": "rewardPool", "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}], "stateMutability": "view", "type": "function"}, # Internal
]

# --- Storage Slots (Derived from DegenerusGameStorage.sol) ---
SLOT_LEVEL_GAMESTATE = 0 # Packed with level (24), gameState (8), etc.
SLOT_JACKPOT_COUNTER = 1 # Packed with jackpotCounter
SLOT_LAST_PRIZE_POOL = 4
SLOT_CURRENT_PRIZE_POOL = 5
SLOT_REWARD_POOL = 7
SLOT_DECIMATOR_HUNDRED_POOL = 9
SLOT_BAF_HUNDRED_POOL = 10
SLOT_LEVEL_EXTERMINATORS = 20
SLOT_TRAIT_BURN_TICKET = 24
SLOT_DAILY_BURN_COUNT = 25 # Start of fixed array

# Constants
TRAIT_ID_TIMEOUT = 420
DAILY_JACKPOT_BPS = [610, 677, 746, 813, 881, 949, 1017, 1085, 1153, 1225]

def get_slot_value(w3, contract_addr, slot_int):
    val = w3.eth.get_storage_at(contract_addr, slot_int)
    return int.from_bytes(val, byteorder='big')

def get_mapping_value_slot(key, map_slot):
    # key is usually bytes32 padded
    # keccak(key . map_slot)
    if isinstance(key, int):
        key_bytes = key.to_bytes(32, byteorder='big')
    elif isinstance(key, str):
        if key.startswith("0x"):
            key_bytes = bytes.fromhex(key[2:]).rjust(32, b'\0')
        else:
            # Assume address
            key_bytes = bytes.fromhex(key).rjust(32, b'\0')
    
    slot_bytes = map_slot.to_bytes(32, byteorder='big')
    return int.from_bytes(keccak(key_bytes + slot_bytes), byteorder='big')

def get_array_element_slot(array_slot, index):
    # Dynamic array data starts at keccak(slot)
    base = int.from_bytes(keccak(array_slot.to_bytes(32, byteorder='big')), byteorder='big')
    return base + index # For simpler types/addresses that fit in 1 slot

def get_fixed_array_slot(base_slot, index, type_size_words=1):
    return base_slot + (index * type_size_words)

def main():
    if not CONTRACT_ADDRESS:
        print("Error: GAME_ADDRESS environment variable not set.")
        sys.exit(1)
        
    if len(sys.argv) < 2:
        print("Usage: python3 predict_advance.py <RNG_WORD_HEX> [RPC_URL]")
        sys.exit(1)

    rng_word_hex = sys.argv[1]
    rng_word = int(rng_word_hex, 16)
    
    rpc = sys.argv[2] if len(sys.argv) > 2 else RPC_URL
    w3 = Web3(Web3.HTTPProvider(rpc))
    
    if not w3.is_connected():
        print("Failed to connect to RPC.")
        sys.exit(1)
        
    print(f"Predicting advanceGame for RNG: {hex(rng_word)}")
    print(f"Contract: {CONTRACT_ADDRESS}")

    # Read Slot 0
    slot0 = get_slot_value(w3, CONTRACT_ADDRESS, SLOT_LEVEL_GAMESTATE)
    # Layout Slot 0:
    # levelStartTime (48) - 0
    # dailyIdx (48) - 48
    # rngRequestTime (48) - 96
    # airdropMapsProcessedCount (32) - 144
    # airdropIndex (32) - 176
    # level (24) - 208
    # lastExterminatedTrait (16) - 232
    # gameState (8) - 248
    
    level = (slot0 >> 208) & 0xFFFFFF
    last_exterminated_trait = (slot0 >> 232) & 0xFFFF
    game_state = (slot0 >> 248) & 0xFF
    
    print(f"Current Level: {level}")
    print(f"Game State: {game_state}")
    
    if game_state == 1: # PreGame / Endgame
        predict_endgame(w3, level, last_exterminated_trait, rng_word)
    elif game_state == 3: # Burn / Daily
        predict_daily(w3, level, rng_word)
    else:
        print("State is not 1 (Endgame) or 3 (Burn). Prediction for Purchase state (2) map drops not implemented.")

def entropy_step(state):
    # Solidity: state ^= state << 7; state ^= state >> 9; state ^= state << 8;
    # All ops mod 2**256
    MASK = (1 << 256) - 1
    state = state & MASK
    state = (state ^ (state << 7)) & MASK
    state = (state ^ (state >> 9)) & MASK
    state = (state ^ (state << 8)) & MASK
    return state

def predict_endgame(w3, level, last_exterminated, rng_word):
    print("\n--- Endgame Prediction ---")
    
    prev_level = level - 1 if level > 0 else 0
    
    # Fetch Prize Pool
    current_prize_pool = get_slot_value(w3, CONTRACT_ADDRESS, SLOT_CURRENT_PRIZE_POOL)
    print(f"Current Prize Pool: {w3.from_wei(current_prize_pool, 'ether')} ETH")
    
    # Exterminator Logic
    if last_exterminated != TRAIT_ID_TIMEOUT:
        print(f"Trait Exterminated: {last_exterminated}")
        
        # Calculate Shares
        # Logic: (prevLevel % 10 == 4 && prevLevel != 4) ? 40% : 30%
        is_40_percent = (prev_level % 10 == 4) and (prev_level != 4)
        exterminator_share = (current_prize_pool * 40 // 100) if is_40_percent else (current_prize_pool * 30 // 100)
        jackpot_pool = current_prize_pool - exterminator_share
        
        print(f"Exterminator Share: {w3.from_wei(exterminator_share, 'ether')} ETH")
        print(f"Jackpot Pool: {w3.from_wei(jackpot_pool, 'ether')} ETH")
        
        # Fetch Exterminator
        if prev_level > 0:
            ex_idx = prev_level - 1
            ex_slot = get_array_element_slot(SLOT_LEVEL_EXTERMINATORS, ex_idx)
            ex_val = get_slot_value(w3, CONTRACT_ADDRESS, ex_slot)
            ex_addr = to_checksum_address(ex_val.to_bytes(20, byteorder='big').rjust(20, b'\0'))
            print(f"Exterminator (Level {prev_level}): {ex_addr}")
            
            # Extermination Jackpot Prediction
            # This uses _executeJackpot with traitShareBpsPacked = DAILY_JACKPOT_SHARES_PACKED (20% per bucket)
            # Bucket 0 Share:
            bucket_share = (jackpot_pool * 2000) // 10000
            
            # Entropy Mutation
            # entropy = rngWord ^ (lvl << 192) -- passed to payExterminationJackpot
            # Inside _resolveTraitWinners (Bucket 0):
            # entropyState = _entropyStep(entropy ^ (traitIdx << 64) ^ traitShare)
            # traitIdx = 0
            
            base_entropy = rng_word ^ (prev_level << 192)
            mixed_entropy = base_entropy ^ bucket_share # (0<<64 is 0)
            final_entropy = entropy_step(mixed_entropy)
            
            predict_specific_trait_jackpot(w3, prev_level, last_exterminated, final_entropy, "Extermination Jackpot")
    else:
        print("Level timed out (No exterminator).")

    # Reward Jackpots (BAF / Decimator)
    # Logic from DegenerusGameEndgameModule._runRewardJackpots
    prev_mod_10 = prev_level % 10
    prev_mod_100 = prev_level % 100
    
    if prev_mod_10 == 0:
        print("\n--- BAF Jackpot Check ---")
        # BAF Jackpot (Flip/Stake based)
        # Winners are based on flips, usually tracked in Jackpots contract or recorded separately.
        # This script focuses on storage-based trait tickets. BAF logic often uses `DegenerusJackpots` contract state.
        # This might be harder to predict without that contract's ABI/storage layout.
        print("BAF Jackpot logic relies on external Jackpot contract state. Skipping detailed winner prediction.")
        
    if prev_mod_10 == 5 and prev_level >= 15 and prev_mod_100 != 95:
         print("\n--- Decimator Jackpot Check ---")
         print("Decimator Jackpot logic relies on external Jackpot contract state. Skipping detailed winner prediction.")

def predict_daily(w3, level, rng_word):
    print("\n--- Daily Jackpot Prediction ---")
    
    # We need to know if it's a "Daily" (end of level) or "Early Burn" 
    # advanceGame calls payDailyJackpot.
    # If rngAndTimeGate returned a word, it implies a daily reset condition was met OR it's a manual advance.
    # Assuming standard daily flow:
    
    # Read jackpotCounter from Slot 1
    slot1 = get_slot_value(w3, CONTRACT_ADDRESS, 1)
    # Slot 1 layout:
    # traitRebuildCursor (32) - 0
    # airdropMultiplier (32) - 32
    # jackpotCounter (8) - 64
    jackpot_counter = (slot1 >> 64) & 0xFF
    print(f"Jackpot Counter: {jackpot_counter}")
    
    # 1. Determine Winning Traits
    # From DegenerusGameJackpotModule._getWinningTraits
    # Depends on dailyBurnCount (SLOT_DAILY_BURN_COUNT)
    
    # Read 80 counts. 10 slots of 8 counts each (packed uint32).
    # SLOT_DAILY_BURN_COUNT to SLOT_DAILY_BURN_COUNT + 9
    counts = []
    for i in range(10):
        val = get_slot_value(w3, CONTRACT_ADDRESS, SLOT_DAILY_BURN_COUNT + i)
        for j in range(8):
            counts.append((val >> (j * 32)) & 0xFFFFFFFF)
    
    winning_traits = get_winning_traits(rng_word, counts)
    print(f"Winning Traits: {winning_traits}")
    
    # 2. Predict Winners for 4 Buckets
    entropy = rng_word ^ (level << 192)
    
    # Bucket shares
    # _traitBucketCounts
    band = ((level % 100) // 20) + 1
    # bucket_counts logic ...
    
    for idx, trait_id in enumerate(winning_traits):
        # Resolve winners
        # Entropy step
        # entropy = _entropyStep(entropy ^ (idx << 64) ^ share) ... share is tricky to know exact amount without pool math
        # BUT winner selection ONLY depends on entropy state and ticket count.
        # The amount share affects entropy if logic `entropyState = _entropyStep(...)` uses share.
        # Checking contract: `entropyState = _entropyStep(entropyState ^ (uint256(traitIdx) << 64) ^ traitShare);
        # YES, share affects entropy for subsequent steps!
        # So we MUST calculate share.
        
        # This requires reading pools.
        pass
        
    print("Full daily prediction requires precise pool math to determine entropy seeds. Implemented trait selection only.")

def get_winning_traits(rng_word, counts):
    # Port of _getWinningTraits
    w = [0] * 4
    
    # Sym 0 (Base 0, Len 8)
    sym = max_idx_in_range(counts, 0, 8)
    col0 = rng_word & 7
    w[0] = (col0 << 3) | sym
    
    # Sym 1 (Base 8, Len 8)
    max_color = max_idx_in_range(counts, 8, 8)
    rand_sym = (rng_word >> 3) & 7
    w[1] = 64 + ((max_color << 3) | rand_sym)
    
    # Sym 2 (Base 16, Len 64)
    max_trait = max_idx_in_range(counts, 16, 64)
    w[2] = 128 + max_trait
    
    # Sym 3 (Random)
    w[3] = 192 + ((rng_word >> 6) & 63)
    
    return w

def max_idx_in_range(counts, base, length):
    end = base + length
    if end > 80: end = 80
    
    max_val = counts[base]
    max_rel = 0
    
    for i in range(base + 1, end):
        v = counts[i]
        if v > max_val:
            max_val = v
            max_rel = i - base
            
    return max_rel

def predict_specific_trait_jackpot(w3, level, trait_id, rng_word, label):
    # Replicate _randTraitTicket logic
    # Need number of holders for traitBurnTicket[level][trait_id]
    
    # 1. Get Map Slot for traitBurnTicket[level]
    # traitBurnTicket is mapping(uint24 => address[][256]) at SLOT_TRAIT_BURN_TICKET
    level_map_slot = get_mapping_value_slot(level, SLOT_TRAIT_BURN_TICKET)
    
    # 2. Get specific trait array slot
    # It's a fixed array of 256 dynamic arrays.
    # Slot = level_map_slot + trait_id
    trait_array_slot = level_map_slot + trait_id
    
    # 3. Get dynamic array length
    length = get_slot_value(w3, CONTRACT_ADDRESS, trait_array_slot)
    
    print(f"  {label} Candidates: {length}")
    
    if length > 0:
        # Predict winner
        # Logic: idx = slice % len
        # slice = randomWord ^ (trait << 128) ^ (salt << 192)
        # salt for exterminator jackpot is usually ... wait, need to check call site.
        # DegenerusGameEndgameModule calls:
        # payExterminationJackpot(..., rngWord, ...)
        # DegenerusGameJackpotModule.payExterminationJackpot calls:
        # _executeJackpot -> _distributeJackpotEth -> _resolveTraitWinners
        # _resolveTraitWinners calls _randTraitTicket with salt = 200 + traitIdx (0..3)
        # But wait, payExterminationJackpot packs traitId into all 4 slots.
        # So it runs 4 times?
        # payExterminationJackpot packs traitId into all 4 slots.
        # So traitIdx 0: traitId, salt 200
        # traitIdx 1: traitId, salt 201
        # ...
        
        # We'll just predict the first one (Main Exterminator Jackpot bucket 0)
        salt = 200
        slice_val = rng_word ^ (trait_id << 128) ^ (salt << 192)
        idx = slice_val % length
        
        # Fetch winner address
        # Data starts at keccak(trait_array_slot)
        data_start = int.from_bytes(keccak(trait_array_slot.to_bytes(32, byteorder='big')), byteorder='big')
        winner_slot = data_start + idx
        winner_val = get_slot_value(w3, CONTRACT_ADDRESS, winner_slot)
        winner_addr = to_checksum_address(winner_val.to_bytes(20, byteorder='big').rjust(20, b'\0'))
        
        print(f"  Predicted Winner (Bucket 0): {winner_addr} (Index {idx})")

if __name__ == "__main__":
    main()
