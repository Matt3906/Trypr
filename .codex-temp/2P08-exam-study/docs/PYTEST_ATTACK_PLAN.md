# Pytest Attack Plan

Use this every single time you practice.

## Step 1: Read the test before writing code

Ask:
- what is the function name?
- what arguments does it receive?
- what exact type must it return?
- is the test checking values, columns, dtype, or shape?

## Step 2: Translate the requirement into plain English

Examples:
- "Return a Series of normalized counts by gender"
- "Create a boolean column where adults are `True`"
- "Convert the date column to datetime"
- "Group by class and compute the mean"

## Step 3: Solve with the simplest pandas or NumPy tool

Typical tools:
- pandas: `drop`, `fillna`, `map`, `groupby`, `value_counts`, `describe`, `to_datetime`
- NumPy: `array`, `arange`, `reshape`, element-wise operations, `mean`, `sum`, slicing

## Step 4: Be exact about the output

Check:
- `Series` vs `DataFrame`
- column names
- index order
- booleans vs strings
- floats vs integers

## Step 5: Run one test file fast

```bash
pytest path/to/test_file.py -q
```

If one test fails:
- read the assertion
- inspect what your function returned
- fix only that mismatch first

## Step 6: Watch for common traps

- forgetting `inplace=True` when expected
- returning a raw array instead of a pandas object
- forgetting `normalize=True`
- forgetting to sort after counting time-based data
- reshaping to an impossible size
- mixing up `axis=0` and `axis=1`
- confusing a view with a copy in NumPy

## Step 7: Keep your exam code simple

Under pressure:
- prefer one clean line over clever code
- avoid unnecessary loops when pandas or NumPy already solves it
- do not overbuild
- match the test, not your imagination
