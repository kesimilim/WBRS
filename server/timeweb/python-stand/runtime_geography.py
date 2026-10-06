"""Pinned approved local geography; no HTTP catalog, external path or network."""
from __future__ import annotations

from functools import lru_cache
import hashlib
from pathlib import Path
import re

from native_credentials import CredentialUnavailable, unique_json
from runtime_mutations import RuntimeInvalidRequest, RuntimeUnavailable


CATALOG_SHA256 = "6d696906e2ca14e09dc8516606567768b6161ceed82f84a0bdf5961ddfa93a05"
_CATALOG = Path(__file__).with_name("geo_catalog.json")
_MAX_CATALOG_BYTES = 65536
_COUNTRY_FIELDS = {"code", "name", "englishName", "regionLabel", "regions", "languageGroup", "segment"}


def _catalog_text(value):
    if (not isinstance(value, str) or not 1 <= len(value) <= 191
            or any(ord(c) < 32 or ord(c) == 127 for c in value)):
        raise RuntimeUnavailable()
    try:
        if len(value.encode("utf-8")) > 764:
            raise RuntimeUnavailable()
    except UnicodeError:
        raise RuntimeUnavailable() from None
    return value


def _decode_catalog(raw):
    if (not isinstance(raw, bytes) or len(raw) > _MAX_CATALOG_BYTES
            or hashlib.sha256(raw).hexdigest() != CATALOG_SHA256):
        raise RuntimeUnavailable()
    try:
        source = unique_json(raw.decode("utf-8"))
        if (type(source) is not dict or set(source) != {"version", "source", "countries"}
                or type(source["version"]) is not int or source["version"] != 2
                or not isinstance(source["source"], str) or type(source["countries"]) is not list
                or not 1 <= len(source["countries"]) <= 100):
            raise RuntimeUnavailable()
        result = {}
        for country in source["countries"]:
            if (type(country) is not dict or set(country) != _COUNTRY_FIELDS
                    or not isinstance(country["code"], str)
                    or re.fullmatch(r"[A-Z]{2}", country["code"]) is None
                    or country["code"] in result or type(country["regions"]) is not list
                    or not 1 <= len(country["regions"]) <= 1000):
                raise RuntimeUnavailable()
            for name in _COUNTRY_FIELDS - {"regions"}:
                _catalog_text(country[name])
            regions = [_catalog_text(region) for region in country["regions"]]
            if len(regions) != len(set(regions)):
                raise RuntimeUnavailable()
            result[country["code"]] = (country["name"], frozenset(regions))
        return result
    except (CredentialUnavailable, UnicodeError, KeyError, TypeError, ValueError):
        raise RuntimeUnavailable() from None


@lru_cache(maxsize=1)
def _catalog():
    try:
        with _CATALOG.open("rb") as stream:
            return _decode_catalog(stream.read(_MAX_CATALOG_BYTES + 1))
    except OSError:
        raise RuntimeUnavailable() from None


def resolve_geography(changes):
    if (type(changes) is not dict or set(changes) != {"countryCode", "region"}
            or not isinstance(changes["countryCode"], str)
            or re.fullmatch(r"[A-Z]{2}", changes["countryCode"]) is None
            or not isinstance(changes["region"], str) or not 1 <= len(changes["region"]) <= 191):
        raise RuntimeInvalidRequest()
    country = _catalog().get(changes["countryCode"])
    if country is None or changes["region"] not in country[1]:
        raise RuntimeInvalidRequest()
    return {"country": country[0], "countryCode": changes["countryCode"], "region": changes["region"]}
