# Mistake Log

Use this after every practice block.

| Date | Topic | What I got wrong | Why it failed | Correct pattern |
|------|-------|------------------|---------------|-----------------|
| 2026-04-08 | Example: pandas groupby | Returned a DataFrame instead of a Series | The test expected a Series | `df.groupby("class")["Survived"].mean()` |
| 2026-04-08 | Example: NumPy reshape | Tried `reshape(4, 8)` on 24 elements | Element count did not match | choose a shape whose product is 24 |
