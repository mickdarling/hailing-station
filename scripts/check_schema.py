#!/usr/bin/env python3
"""Validate every fixture in fixtures/frames against fixtures/schema/frame-v<N>.schema.json (#28).

Uses the `jsonschema` package when present; otherwise a small built-in checker covering the subset
this schema uses (type, required, additionalProperties, properties, enum, const, minimum, maximum,
minLength, maxLength, allOf/if/then, $ref into $defs). Exit 1 on any failure.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _type_ok(value, kind: str) -> bool:
    checks = {
        "object": lambda v: isinstance(v, dict), "array": lambda v: isinstance(v, list),
        "string": lambda v: isinstance(v, str), "boolean": lambda v: isinstance(v, bool),
        "integer": lambda v: (isinstance(v, int) and not isinstance(v, bool)) or (isinstance(v, float) and v.is_integer()),
        "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool), "null": lambda v: v is None,
    }
    return checks[kind](value)


def validate(value, schema: dict, root: dict, path: str = "$") -> list[str]:
    errors: list[str] = []
    if "$ref" in schema:
        target = root
        for part in schema["$ref"].lstrip("#/").split("/"):
            target = target[part]
        return validate(value, target, root, path)
    if "type" in schema and not _type_ok(value, schema["type"]):
        return [f"{path}: expected {schema['type']}"]
    if "const" in schema and value != schema["const"]:
        errors.append(f"{path}: expected const {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: {value!r} not in enum")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{path}: {value} below minimum")
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(f"{path}: {value} above maximum")
    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            errors.append(f"{path}: shorter than minLength")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            errors.append(f"{path}: longer than maxLength")
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{path}: missing required {key}")
        props = schema.get("properties", {})
        for key, sub in props.items():
            if key in value:
                errors.extend(validate(value[key], sub, root, f"{path}.{key}"))
        if schema.get("additionalProperties") is False:
            errors.extend(f"{path}: unexpected property {key}" for key in value if key not in props)
    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            errors.append(f"{path}: fewer than minItems")
        if "items" in schema:
            for index, item in enumerate(value):
                errors.extend(validate(item, schema["items"], root, f"{path}[{index}]"))
    for rule in schema.get("allOf", []):
        if "if" in rule:
            if not validate(value, rule["if"], root, path):
                errors.extend(validate(value, rule.get("then", {}), root, path))
        else:
            errors.extend(validate(value, rule, root, path))
    return errors


def main() -> int:
    schemas = sorted(
        (ROOT / "fixtures" / "schema").glob("frame-v*.schema.json"),
        key=lambda p: int(p.name.split("frame-v")[1].split(".")[0]),
    )
    if not schemas:
        print("check_schema: no schema file found")
        return 1
    schema = json.loads(schemas[-1].read_text())
    try:
        import jsonschema  # type: ignore

        def check(doc):
            return [str(e.message) for e in jsonschema.Draft202012Validator(schema).iter_errors(doc)]
        engine = "jsonschema"
    except ImportError:
        def check(doc):
            return validate(doc, schema, schema)
        engine = "built-in"
    known_types = set(schema.get("$defs", {}))
    failures = 0
    for fixture in sorted((ROOT / "fixtures" / "frames").glob("*.json")):
        doc = json.loads(fixture.read_text())
        problems = check(doc)
        if doc.get("type") not in known_types:
            # An unknown type may carry any payload object, but the payload key itself is still required.
            problems = [p for p in problems if not p.startswith("$.payload.") and "$.payload:" not in p]
        if problems:
            failures += 1
            print(f"{fixture.name}: " + "; ".join(problems))
    # Negative fixtures: every file under fixtures/invalid must FAIL validation (or be rejected by the decoder
    # for reasons the schema cannot express; those carry "schema": "pass" in a sidecar-free comment key).
    invalid_ok = 0
    invalid_dir = ROOT / "fixtures" / "invalid"
    for fixture in sorted(invalid_dir.glob("*.json")) if invalid_dir.is_dir() else []:
        doc = json.loads(fixture.read_text())
        if doc.get("_expect") == "schema-pass":
            continue  # rejected only by the Swift decoder; the Swift test covers it
        if not check({k: v for k, v in doc.items() if k != "_expect"}):
            failures += 1
            print(f"{fixture.name}: expected to fail validation but passed")
        else:
            invalid_ok += 1
    total = len(list((ROOT / "fixtures" / "frames").glob("*.json")))
    print(f"check_schema ({engine}): {total} fixtures, {invalid_ok} negatives rejected, {failures} failing")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
