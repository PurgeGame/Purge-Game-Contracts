function calculateOdds() {
    const risks = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
    const TRIALS = 200;

    console.log(`### Odds of Winning At Least Once (200 Attempts)`);
    console.log("| Risk | Single Win Chance | Odds of Winning >= 1 (200 Tries) | Expected Wins (200 Tries) |");
    console.log("| :--- | :--- | :--- | :--- |");

    for (const r of risks) {
        const pWin = Math.pow(0.5, r);
        const pLoss = 1 - pWin;
        const pAllLoss = Math.pow(pLoss, TRIALS);
        const pAtLeastOne = 1 - pAllLoss;
        
        const expected = TRIALS * pWin;
        
        const oddsStr = (pAtLeastOne * 100).toFixed(2) + "%";
        const singleStr = (pWin * 100).toPrecision(3) + "%"; // e.g. 0.0488%
        
        console.log(`| **${r}** | ${singleStr} (1/${Math.round(1/pWin)}) | **${oddsStr}** | ${expected.toFixed(2)} |`);
    }
}

calculateOdds();
