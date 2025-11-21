function calculateEVTable(principal) {
    const distances = Array.from({length: 20}, (_, i) => (i + 1) * 10); // 10, 20, ..., 200
    const risks = [1, 3, 5, 7, 9, 11]; // Odd risk factors

    // Purgecoin constants
    const BASE_RATE_BPS = 100; // 1%
    const MAX_DISTANCE_CAP = 200;
    const RISK_BONUS_BPS_PER_UNIT = 12;

    console.log(`### Total Expected Value (EV) for a ${principal} PURGE Stake (Corrected)`);
    console.log("Assuming neutral EV coinflips (doubling on propagation). EV is driven by Initial Boost.");
    let header = "| Distance |";
    let separator = "| :--- |";
    for (const r of risks) {
        header += ` Risk ${r} |`;
        separator += ` :--- |`;
    }
    console.log(header);
    console.log(separator);

    for (const d of distances) {
        let row = `| **${d}** |`;
        for (const r of risks) {
            const cappedDist = Math.min(d, MAX_DISTANCE_CAP);
            const levelBps = BASE_RATE_BPS + cappedDist;
            const riskBps = RISK_BONUS_BPS_PER_UNIT * (r - 1);
            const stepBps = levelBps + riskBps;
            const rate = 1 + stepBps / 10000;

            // The principal is boosted ONCE at start.
            // Then it doubles (x2) every propagation step (Risk-1 steps).
            // Probability of surviving propagation is 0.5^(Risk-1).
            // Net EV of propagation = 1.
            // Final flip: Win 2x (approx), Prob 0.5. EV = 1.
            // Total EV = Boosted Principal.

            const boost = Math.pow(rate, d);
            const totalEV = principal * boost;
            
            // Formating
            let val = totalEV.toFixed(2);
            // If massive, use scientific?
            if (totalEV > 1000000) val = (totalEV/1000000).toFixed(2) + "M";
            
            row += ` ${val} |`;
        }
        console.log(row);
    }
}

calculateEVTable(1000); 
