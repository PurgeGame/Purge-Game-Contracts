function calculateEVTable(principal) {
    const distances = Array.from({length: 20}, (_, i) => (i + 1) * 10); // 10, 20, ..., 200
    const risks = [1, 3, 5, 7, 9, 11]; // Odd risk factors

    // Purgecoin constants
    const BASE_RATE_BPS = 100; // 1%
    const MAX_DISTANCE_CAP = 200;
    const RISK_BONUS_BPS_PER_UNIT = 12;
    const BPS_CAP = 250; // New Change

    console.log(`### Total Expected Value (EV) for a ${principal} PURGE Stake (With 250 BPS Cap)`);
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
            
            let stepBps = levelBps + riskBps;
            if (stepBps > BPS_CAP) stepBps = BPS_CAP; // The Cap
            
            const rate = 1 + stepBps / 10000;

            // EV = Principal * (1+Rate)^d
            const boost = Math.pow(rate, d);
            const totalEV = principal * boost;
            
            // Formating
            let val = totalEV.toFixed(2);
            if (totalEV > 1000000) val = (totalEV/1000000).toFixed(2) + "M";
            
            row += ` ${val} |`;
        }
        console.log(row);
    }
}

calculateEVTable(1000);