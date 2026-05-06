import numpy as np


def build_zero_grid():
    return np.zeros((2, 3))


def reshape_sequence():
    return np.arange(1, 13).reshape(3, 4)


def square_numbers(numbers):
    return numbers ** 2


def column_means(matrix):
    return matrix.mean(axis=0)


def last_two_columns(matrix):
    return matrix[:, -2:]
