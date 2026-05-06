# NumPy Quiz 5 Review

This sheet is based on your `quiz5 - 2p08.pdf`.

## Core array creation

Know these cold:

```python
np.array([2, 3, 5, 7, 11])
np.zeros((2, 3))
np.ones((3, 2))
np.full((2, 2), 9)
np.arange(1, 21)
np.arange(1, 21).reshape(4, 5)
```

## Must-know facts

- `numpy.ndarray` is the array type.
- `dtype` tells you the element type.
- `ndim` tells you the number of dimensions.
- `shape` is a tuple describing dimensions.
- reshaping does not change the number of elements
- `reshape` returns a view when possible

## Element-wise operations

These apply to every element:

```python
numbers * 2
2 * numbers
numbers ** 3
np.sqrt(numbers)
np.add(a, b)
np.multiply(a, b)
```

## Broadcasting

Broadcasting means NumPy can apply operations across compatible shapes.

Examples:

```python
np.arange(1, 6) * 2

matrix = np.array([[10, 20, 30],
                   [40, 50, 60]])
row = np.array([2, 4, 6])
np.multiply(matrix, row)
```

The second example works because the row length matches each matrix row.

## Reductions

Know what these do:

```python
arr.sum()
arr.min()
arr.max()
arr.mean()
arr.std()
arr.var()
```

For 2D arrays:
- `axis=0` means calculate down the rows, giving a result for each column
- `axis=1` means calculate across the columns, giving a result for each row

Example:

```python
grades.mean(axis=1)
```

This gives each student's average if each row is one student.

## Slicing and indexing

Know these patterns:

```python
grades[0, 1]
grades[1]
grades[0:2]
grades[[1, 3]]
grades[:, 0]
grades[:, 1:3]
grades[:, [0, 2]]
```

And this one from the quiz:

```python
d1 = np.array([[0, 1, 3], [4, 2, 9]])
d2 = d1[:, 1:]
```

`d2` becomes:

```python
array([[1, 3],
       [2, 9]])
```

## Views vs copies

Important:
- slices often create views
- a view sees updates to the original data
- changing the view can also change the original array

Example idea:

```python
numbers2 = numbers[0:3]
```

`numbers2` is not a totally separate copy by default.

## Fast verbal definitions

If you want a quick self-test, say these out loud:
- reshape: "change dimensions without changing element count"
- broadcasting: "apply operations across compatible shapes"
- axis 0: "do the calculation by column"
- axis 1: "do the calculation by row"
