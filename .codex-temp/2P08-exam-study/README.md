# 2P08 Final Exam Study Kit

This project is built for your final exam on Friday, April 10, 2026 from 7:00 PM to 9:00 PM.

The exam format is practical and pytest-driven:
- you will be given Python functions to complete
- your work will be graded with `pytest`
- the core topics are `NumPy`, `Pandas`, and visualization

## How to use this folder

1. Start with [docs/EXAM_SCOPE.md](./docs/EXAM_SCOPE.md) to see exactly what the exam is asking from you.
2. Follow [docs/STUDY_PLAN_APRIL_8_TO_10.md](./docs/STUDY_PLAN_APRIL_8_TO_10.md) from Wednesday to Friday.
3. Use [docs/PRACTICE_LADDER.md](./docs/PRACTICE_LADDER.md) to move from easiest to hardest.
4. Use [docs/PYTEST_ATTACK_PLAN.md](./docs/PYTEST_ATTACK_PLAN.md) every time you practice.
5. Review [docs/NUMPY_QUIZ_5_REVIEW.md](./docs/NUMPY_QUIZ_5_REVIEW.md) for the NumPy concepts from Quiz 5.
6. Start with the first practice file, then move upward in difficulty.
7. Check yourself with the matching test file for each level:

```bash
pytest practice/test_level_01_numpy.py -q
pytest practice/test_level_02_pandas_cleaning.py -q
pytest practice/test_mock_exam_01.py -q
pytest practice/test_level_04_transport_mock.py -q
```

8. After each session, write down what tripped you up in [docs/MISTAKE_LOG.md](./docs/MISTAKE_LOG.md).

## What this folder includes

- a dated 3-day study plan
- a progressive difficulty ladder
- an exam-style solving method
- a summary of the exact resources you provided
- a NumPy Quiz 5 review sheet
- several practice files that get harder
- an answer key to compare against only after you try the starter on your own

## Source materials used

- `lab-03-study-guide-titanic-analysis-Matt3906`
- `lab-03-study-guide-traffic-analysis-Matt3906`
- `quiz5 - 2p08.pdf`
- your teacher's April 7, 2026 exam announcement

## Missing but expected materials

Your teacher also mentioned:
- Quiz 6 (`pandas`)
- Data Challenge

If you send those too, this kit can be tightened even more.
