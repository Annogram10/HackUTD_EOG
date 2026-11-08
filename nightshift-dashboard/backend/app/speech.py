"""Spoken-text helpers for the glasses: short sentences, numbers spelled out. Every number comes from the data."""

_ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
_TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()


def int_words(n: int) -> str:
    if n < 0:
        return "minus " + int_words(-n)
    if n < 20:
        return _ONES[n]
    if n < 100:
        return _TENS[n // 10] + ("" if n % 10 == 0 else " " + _ONES[n % 10])
    if n < 1000:
        return _ONES[n // 100] + " hundred" + ("" if n % 100 == 0 else " " + int_words(n % 100))
    if n < 1_000_000:
        return int_words(n // 1000) + " thousand" + ("" if n % 1000 == 0 else " " + int_words(n % 1000))
    return str(n)


def num_words(x: float, decimals: int = 0) -> str:
    x = round(float(x), decimals)
    whole = int(abs(x))
    out = int_words(whole)
    if decimals and abs(x) - whole > 0:
        frac = f"{abs(x):.{decimals}f}".split(".")[1]
        out += " point " + " ".join(_ONES[int(d)] for d in frac)
    return ("minus " + out) if x < 0 else out


def dollars(x: float) -> str:
    n = int(round(x))
    return f"{int_words(n)} dollar{'' if n == 1 else 's'}"


def hours(x: float) -> str:
    s = num_words(x, 1)
    return f"{s} hour{'' if s == 'one' else 's'}"


def facility(name: str) -> str:
    """'S5 Facility C' -> 'S five Facility C' so it is read out properly."""
    return " ".join(("S " + int_words(int(w[1:]))) if len(w) > 1 and w[0] == "S" and w[1:].isdigit() else w for w in name.split())
