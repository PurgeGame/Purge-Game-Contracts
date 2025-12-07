function calculatePayoutTable(principal) {
    const distances = Array.from({length: 20}, (_, i) => (i + 1) * 10); 
    const risks = [1, 3, 5, 7, 9, 11];

    const BASE_RATE_BPS = 100;
    const MAX_DISTANCE_CAP = 200;
    const RISK_BONUS_BPS_PER_UNIT = 12;
    const BPS_CAP = 250; 

    console.log(`### Max Payout for 1k DEGEN Stake (If Survived)`);
    let header = "| Dist |";
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
            if (stepBps > BPS_CAP) stepBps = BPS_CAP;
            
            const rate = 1 + stepBps / 10000;
            
            // Payout = Principal * Boost * (2^Risk)
            const boost = Math.pow(rate, d);
            const riskMult = Math.pow(2, r);
            const payout = principal * boost * riskMult;
            
            // Format: x.yk or integer k
            let val = payout / 1000;
            let str = "";
            
            if (val < 10) {
                str = val.toFixed(1) + "k";
            } else {
                str = Math.round(val) + "k";
            }
            
            // If massive (e.g. > 1000k), maybe switch to M?
            // User said "integer k". I'll stick to k unless it's absurdly long.
            if (val >= 1000) {
                str = (val/1000).toFixed(1) + "M";
                if (val/1000 >= 10) str = Math.round(val/1000) + "M";
            }
            
            row += ` ${str} |`;
        }
        console.log(row);
    }
}

calculatePayoutTable(1000); 
