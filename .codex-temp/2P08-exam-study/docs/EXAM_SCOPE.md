# Exam Scope

## Teacher message summary

The final exam is on Friday, April 10, 2026 from 7:00 PM to 9:00 PM.

The format is very similar to the lab tests:
- you complete Python functions
- grading is done with `pytest`
- passing the tests is the main target

Topics explicitly named by your teacher:
- data analysis using `pandas`
- `NumPy`
- visualization

Study materials explicitly named by your teacher:
- all Lab Test #3 study materials
- Quiz #5 (`NumPy`)
- Quiz #6 (`pandas`)
- Data Challenge

## Patterns from the two Lab Test #3 study guides

Both study guides follow the same exam-friendly structure:

1. Load a CSV into a class.
2. Clean the data.
3. Transform the data by creating new columns.
4. Return exact `Series` or `DataFrame` results.
5. Use plotting functions for visualization tasks.
6. Satisfy very specific `pytest` expectations.

## What you should expect on the exam

Based on the teacher message and the provided study guides, likely tasks include:
- dropping or filling missing data
- converting columns to datetime
- mapping coded values to readable labels
- creating new columns from old columns
- grouping with `groupby`
- returning normalized counts or means
- checking dtypes and shapes
- writing small visualizations with `matplotlib` or `seaborn`

## High-value details from the provided tests

The tests do not just check "close enough." They check details like:
- exact return type: `pd.Series` vs `pd.DataFrame`
- exact column names
- datetime conversion
- boolean columns
- normalized counts summing to `1.0`
- index ordering or `idxmin()` behavior
- summary statistics existing under expected column names

## NumPy topics confirmed by Quiz 5

Quiz 5 heavily reinforces:
- `np.array`
- `np.zeros`, `np.ones`, `np.full`
- `np.arange`
- `reshape`
- `dtype`
- `ndim`
- `shape`
- element-wise arithmetic
- broadcasting
- reductions like `sum`, `min`, `max`, `mean`, `std`, `var`
- universal functions like `np.sqrt`, `np.add`, `np.multiply`
- slicing and row/column selection
- views vs copies
- using `axis=0` and `axis=1`

## Most important mindset

This exam is not really "write fancy code from memory."

It is:
- read the prompt carefully
- infer what the tests will check
- return the exact structure expected
- use the simplest correct pandas or NumPy operation
- verify with `pytest`
