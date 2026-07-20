"""Deterministic random-seed controls."""

import os
import random

import numpy as np
from numpy.random import Generator


def set_deterministic_seed(seed: int) -> Generator:
    """Seed standard and NumPy random generators and return a modern generator."""
    if seed < 0:
        raise ValueError("Seed must be nonnegative.")
    os.environ["PYTHONHASHSEED"] = str(seed)
    random.seed(seed)
    np.random.seed(seed)
    return np.random.default_rng(seed)
