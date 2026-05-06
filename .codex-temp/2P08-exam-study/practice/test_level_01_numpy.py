import numpy as np

import level_01_numpy_starter as level


def test_build_zero_grid():
    result = level.build_zero_grid()
    assert isinstance(result, np.ndarray)
    assert result.shape == (2, 3)
    assert np.array_equal(result, np.zeros((2, 3)))


def test_reshape_sequence():
    result = level.reshape_sequence()
    assert isinstance(result, np.ndarray)
    assert result.shape == (3, 4)
    assert result[0, 0] == 1
    assert result[-1, -1] == 12


def test_square_numbers():
    result = level.square_numbers(np.array([2, 3, 4]))
    assert np.array_equal(result, np.array([4, 9, 16]))


def test_column_means():
    matrix = np.array([[10, 20, 30], [20, 40, 60]])
    result = level.column_means(matrix)
    assert np.array_equal(result, np.array([15.0, 30.0, 45.0]))


def test_last_two_columns():
    matrix = np.array([[1, 2, 3, 4], [5, 6, 7, 8]])
    result = level.last_two_columns(matrix)
    assert np.array_equal(result, np.array([[3, 4], [7, 8]]))
