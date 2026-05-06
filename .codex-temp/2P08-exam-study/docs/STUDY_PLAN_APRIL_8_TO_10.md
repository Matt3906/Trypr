# Study Plan: April 8 to April 10, 2026

## Main goal

By Friday evening, you should be able to:
- read a small pandas or NumPy function prompt
- write the function calmly
- predict what `pytest` is likely to check
- fix failures quickly without guessing

## Wednesday, April 8: Pandas foundations + Titanic

### Session 1: 60 to 90 minutes
- Read [EXAM_SCOPE.md](./EXAM_SCOPE.md).
- Read the Titanic test file first.
- For every test, say out loud what the function must return.
- Make a one-page summary of these pandas moves:
  - `drop`
  - `fillna`
  - `mode`
  - `mean`
  - `map`
  - boolean columns
  - `groupby`
  - `describe`

### Session 2: 60 to 90 minutes
- Open the Titanic implementation and rewrite each function idea in plain English.
- Focus on:
  - cleaning missing values
  - creating columns from rules
  - grouping and returning exact outputs
- Run the Titanic tests if you want a confidence pass:

```bash
cd "/Users/matt3906/Documents/School/COSC 2P08/Code/lab-03-study-guide-titanic-analysis-Matt3906"
pytest test_titanic_analysis.py -q
```

### End-of-day checkpoint
- Can you explain the difference between cleaning, transforming, and analyzing?
- Can you tell when a result should be a `Series` or `DataFrame`?
- Can you create a boolean column from conditions?

## Thursday, April 9: Traffic study guide + NumPy review

### Session 1: 60 to 90 minutes
- Read the traffic test file first.
- Focus on:
  - `pd.to_datetime`
  - extracting `dt.year`
  - filtering rows by condition
  - normalized `value_counts`
  - sorting by index when time order matters

### Session 2: 45 to 60 minutes
- Review [NUMPY_QUIZ_5_REVIEW.md](./NUMPY_QUIZ_5_REVIEW.md).
- Complete Level 1 from [PRACTICE_LADDER.md](./PRACTICE_LADDER.md).
- Practice these from memory:
  - `np.arange(1, 21).reshape(4, 5)`
  - `arr.mean(axis=0)`
  - `arr.mean(axis=1)`
  - broadcasting with a scalar
  - broadcasting with a compatible row vector
  - slicing rows and columns

### Session 3: 45 to 75 minutes
- Complete Level 2 first, then move into Level 3 if time allows.
- Do not look at the answer keys on the first attempt.
- Run:

```bash
pytest practice/test_level_02_pandas_cleaning.py -q
pytest practice/test_mock_exam_01.py -q
```

### End-of-day checkpoint
- Can you tell when `axis=0` means by column?
- Can you reshape without changing the number of elements?
- Can you explain broadcasting in one sentence?
- Can you filter then group in pandas without freezing?

## Friday, April 10: Timed practice + light review

### Session 1: 60 minutes, timed
- Do Level 4 from the practice ladder as your full timed run.
- Use [PYTEST_ATTACK_PLAN.md](./PYTEST_ATTACK_PLAN.md) exactly.
- Limit yourself to simple, direct code.

### Session 2: 30 to 45 minutes
- Review only mistakes from [MISTAKE_LOG.md](./MISTAKE_LOG.md).
- Re-do the exact concepts you missed.
- Do not start learning brand-new topics today.

### Pre-exam warm-up: 20 to 30 minutes
- Review your mini cheatsheet.
- Practice 3 tiny things only:
  - one `groupby`
  - one `reshape`
  - one boolean filter
- Stop before you get mentally tired.

## Rule for all 3 days

When practicing, do this order every time:

1. Read the test or prompt first.
2. Write what the function must return.
3. Implement the smallest correct version.
4. Run `pytest`.
5. Fix one failure at a time.
6. Write the mistake down once it is solved.
