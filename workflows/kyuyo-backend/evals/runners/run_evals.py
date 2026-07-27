#!/usr/bin/env python3
"""Run kyuyo AI eval validation and hard-check scoring."""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml


ROOT = Path(__file__).resolve().parents[2]
REGISTRY_PATH = ROOT / "registry" / "evals.json"
CASES_DIR = ROOT / "evals" / "cases"
DEFAULT_OUTPUTS_DIR = ROOT / "evals" / "outputs"
DEFAULT_REPORTS_DIR = ROOT / "evals" / "reports"

REQUIRED_KEYS = [
    "id",
    "title",
    "source_period",
    "tags",
    "trigger_when",
    "case_input",
    "expected_behavior",
    "hard_checks",
    "semantic_rubric",
    "blocking_failures",
    "evaluator_notes",
]


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def project_path(path: str) -> Path:
    return ROOT.parent / path


def load_registry() -> list[dict[str, Any]]:
    if not REGISTRY_PATH.exists():
        fail(f"missing registry: {REGISTRY_PATH}")
    with REGISTRY_PATH.open(encoding="utf-8") as fp:
        data = json.load(fp)
    cases = data.get("cases")
    if not isinstance(cases, list):
        fail(f"{REGISTRY_PATH}: cases must be a list")
    return cases


def case_files() -> list[Path]:
    return sorted(CASES_DIR.glob("*.yaml"))


def load_case(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as fp:
            data = yaml.safe_load(fp)
    except yaml.YAMLError as exc:
        fail(f"{path}: YAML syntax error: {exc}")
    if not isinstance(data, dict):
        fail(f"{path}: YAML root must be a mapping")
    return data


def is_non_empty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def is_non_empty_list(value: Any) -> bool:
    return isinstance(value, list) and bool(value)


def validate_case_schema(path: Path, data: dict[str, Any]) -> tuple[Path, str | None, list[str]]:
    errors: list[str] = []
    missing = [key for key in REQUIRED_KEYS if key not in data]
    if missing:
        errors.append(f"missing keys: {', '.join(missing)}")

    case_id = data.get("id")
    if not is_non_empty_string(case_id):
        errors.append("id is required")

    for key in ["tags", "trigger_when", "expected_behavior", "blocking_failures"]:
        if not is_non_empty_list(data.get(key)):
            errors.append(f"{key} must be a non-empty array")

    case_input = data.get("case_input")
    if isinstance(case_input, dict):
        if not is_non_empty_string(case_input.get("user_prompt")):
            errors.append("case_input.user_prompt is required")
    else:
        errors.append("case_input must be a mapping")

    hard_checks = data.get("hard_checks")
    if isinstance(hard_checks, dict):
        if not isinstance(hard_checks.get("must_include"), list):
            errors.append("hard_checks.must_include must be an array")
        if not isinstance(hard_checks.get("must_not_include"), list):
            errors.append("hard_checks.must_not_include must be an array")
    else:
        errors.append("hard_checks must be a mapping")

    semantic_rubric = data.get("semantic_rubric")
    if isinstance(semantic_rubric, dict):
        for score_key in ["score_0", "score_1", "score_2"]:
            if not isinstance(semantic_rubric.get(score_key), list):
                errors.append(f"semantic_rubric.{score_key} must be an array")
    else:
        errors.append("semantic_rubric must be a mapping")

    return path, case_id if isinstance(case_id, str) else None, errors


def validate_all() -> list[str]:
    registry = load_registry()
    registry_paths = [entry["path"] for entry in registry if isinstance(entry, dict) and "path" in entry]
    registry_ids = [entry["id"] for entry in registry if isinstance(entry, dict) and "id" in entry]
    errors: list[str] = []

    for entry in registry:
        if not isinstance(entry, dict):
            errors.append(f"registry entry must be a mapping: {entry!r}")
            continue
        if "path" not in entry or "id" not in entry:
            errors.append(f"registry entry missing id/path: {entry!r}")
            continue
        if not project_path(entry["path"]).exists():
            errors.append(f"registry path missing: {entry['path']}")

    loaded_cases = [(path, load_case(path)) for path in case_files()]
    schema_results = [validate_case_schema(path, data) for path, data in loaded_cases]
    for path, _case_id, case_errors in schema_results:
        for error in case_errors:
            errors.append(f"{path}: {error}")

    case_ids = [case_id for _path, case_id, _case_errors in schema_results if case_id]
    duplicate_ids = sorted({case_id for case_id in case_ids if case_ids.count(case_id) > 1})
    if duplicate_ids:
        errors.append(f"duplicate case ids: {', '.join(duplicate_ids)}")

    actual_project_paths = [str(path.relative_to(ROOT.parent)) for path in case_files()]
    if sorted(registry_paths) != sorted(actual_project_paths):
        errors.append("registry paths do not match cases directory")
    if sorted(registry_ids) != sorted(case_ids):
        errors.append("registry ids do not match YAML ids")

    return errors


def normalize(value: Any) -> str:
    return str(value).lower()


def contains_token(text: str, token: Any) -> bool:
    return normalize(token) in normalize(text)


def score_case(data: dict[str, Any], output_text: str) -> dict[str, Any]:
    hard_checks = data["hard_checks"]
    must_include = hard_checks["must_include"]
    must_not_include = hard_checks["must_not_include"]

    missing_required = [token for token in must_include if not contains_token(output_text, token)]
    forbidden_hits = [token for token in must_not_include if contains_token(output_text, token)]
    hard_pass = not missing_required and not forbidden_hits

    return {
        "id": data["id"],
        "title": data["title"],
        "hard_check_pass": hard_pass,
        "missing_required": missing_required,
        "forbidden_hits": forbidden_hits,
        "suggested_hard_score": 2 if hard_pass else (1 if not forbidden_hits else 0),
        "blocking_failures_for_manual_review": data["blocking_failures"],
        "semantic_rubric_for_manual_review": data["semantic_rubric"],
    }


def build_model_prompt(data: dict[str, Any]) -> str:
    case_input = data["case_input"]
    prompt_parts = [
        "你是在 kyuyo-backend 项目里执行一个 AI 行为评估用例。",
        "请按用户问题完成任务，回答必须遵守 case 中的期望行为和项目工作流约束。",
        "",
        f"Case id: {data['id']}",
        f"Title: {data['title']}",
        "",
        "User prompt:",
        str(case_input["user_prompt"]).strip(),
    ]

    available_context = case_input.get("available_context")
    if available_context:
        prompt_parts.extend(["", "Available context:"])
        prompt_parts.extend(f"- {item}" for item in available_context)

    prompt_parts.extend(["", "Expected behavior:"])
    prompt_parts.extend(f"- {item}" for item in data["expected_behavior"])

    prompt_parts.extend(["", "Hard checks that a good answer should satisfy:"])
    prompt_parts.append("Must include:")
    prompt_parts.extend(f"- {item}" for item in data["hard_checks"]["must_include"])
    prompt_parts.append("Must avoid:")
    prompt_parts.extend(f"- {item}" for item in data["hard_checks"]["must_not_include"])

    return "\n".join(prompt_parts).strip() + "\n"


def call_model(prompt: str, model: str) -> str:
    if not os.environ.get("OPENAI_API_KEY"):
        fail("OPENAI_API_KEY is required for run")
    try:
        from openai import OpenAI
    except ImportError:
        fail("openai Python package is required for run")
    client = OpenAI()
    response = client.responses.create(
        model=model,
        input=[
            {
                "role": "system",
                "content": "You are a careful software engineering assistant. Follow the user and project instructions exactly.",
            },
            {
                "role": "user",
                "content": prompt,
            },
        ],
    )
    output_text = getattr(response, "output_text", None)
    if not output_text:
        fail("model response did not include output_text")
    return output_text


def find_case(case_id: str) -> dict[str, Any] | None:
    for path in case_files():
        data = load_case(path)
        if data.get("id") == case_id:
            return data
    return None


def print_validation(errors: list[str], as_json: bool) -> bool:
    result = {"command": "validate", "pass": not errors, "errors": errors}
    if as_json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    elif errors:
        for error in errors:
            print(f"FAIL {error}")
    else:
        print("OK eval validation passed")
    return not errors


def print_scores(scores: list[dict[str, Any]], as_json: bool) -> bool:
    passed = all(score["hard_check_pass"] for score in scores)
    result = {"command": "score", "pass": passed, "scores": scores}
    if as_json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        for score in scores:
            status = "PASS" if score["hard_check_pass"] else "FAIL"
            print(f"{status} {score['id']} hard_score={score['suggested_hard_score']}")
            if score["missing_required"]:
                print(f"  missing_required: {', '.join(map(str, score['missing_required']))}")
            if score["forbidden_hits"]:
                print(f"  forbidden_hits: {', '.join(map(str, score['forbidden_hits']))}")
    return passed


def write_report(payload: dict[str, Any], report_path: str | None) -> None:
    if not report_path:
        return
    path = Path(report_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def run_cases(case_id: str | None, model: str, outputs_dir: str, report_path: str | None, as_json: bool) -> bool:
    errors = validate_all()
    if errors:
        return print_validation(errors, as_json)

    selected_cases: list[dict[str, Any]] = []
    if case_id:
        data = find_case(case_id)
        if not data:
            fail(f"case not found: {case_id}")
        selected_cases.append(data)
    else:
        selected_cases = [load_case(path) for path in case_files()]

    output_root = Path(outputs_dir)
    output_root.mkdir(parents=True, exist_ok=True)

    run_results: list[dict[str, Any]] = []
    scores: list[dict[str, Any]] = []
    for data in selected_cases:
        prompt = build_model_prompt(data)
        output_text = call_model(prompt, model)
        output_path = output_root / f"{data['id']}.txt"
        output_path.write_text(output_text, encoding="utf-8")
        score = score_case(data, output_text)
        scores.append(score)
        run_results.append({
            "id": data["id"],
            "model": model,
            "output_path": str(output_path),
            "score": score,
        })

    passed = all(score["hard_check_pass"] for score in scores)
    payload = {
        "command": "run",
        "pass": passed,
        "model": model,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "results": run_results,
    }
    write_report(payload, report_path)

    if as_json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        for result in run_results:
            status = "PASS" if result["score"]["hard_check_pass"] else "FAIL"
            print(f"{status} {result['id']} model={model} output={result['output_path']} hard_score={result['score']['suggested_hard_score']}")
    return passed


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run kyuyo AI evals")
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate = subparsers.add_parser("validate", help="Validate eval assets")
    validate.add_argument("--json", action="store_true", help="Print JSON")

    score = subparsers.add_parser("score", help="Score model output hard checks")
    score.add_argument("--case", dest="case_id", help="Case id to score")
    score.add_argument("--output", help="Output text file for one case")
    score.add_argument("--outputs-dir", default=str(DEFAULT_OUTPUTS_DIR), help="Directory containing <case-id>.txt files")
    score.add_argument("--json", action="store_true", help="Print JSON")

    run = subparsers.add_parser("run", help="Call a model, save outputs, and score hard checks")
    run.add_argument("--case", dest="case_id", help="Case id to run")
    run.add_argument("--model", default=os.environ.get("OPENAI_EVAL_MODEL", "gpt-5"), help="OpenAI model name")
    run.add_argument("--outputs-dir", default=str(DEFAULT_OUTPUTS_DIR), help="Directory to write <case-id>.txt outputs")
    run.add_argument(
        "--report",
        default=str(DEFAULT_REPORTS_DIR / "latest.json"),
        help="JSON report path. Pass an empty string to skip writing a report.",
    )
    run.add_argument("--json", action="store_true", help="Print JSON")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.command == "validate":
        return 0 if print_validation(validate_all(), args.json) else 1

    if args.command == "run":
        return 0 if run_cases(args.case_id, args.model, args.outputs_dir, args.report, args.json) else 1

    errors = validate_all()
    if errors:
        return 0 if print_validation(errors, args.json) else 1
    scores: list[dict[str, Any]] = []
    if args.case_id:
        if not args.output:
            fail("--output is required with --case")
        data = find_case(args.case_id)
        if not data:
            fail(f"case not found: {args.case_id}")
        output_path = Path(args.output)
        if not output_path.exists():
            fail(f"output file missing: {output_path}")
        scores.append(score_case(data, output_path.read_text(encoding="utf-8")))
    else:
        outputs_dir = Path(args.outputs_dir)
        for path in case_files():
            data = load_case(path)
            output_path = outputs_dir / f"{data['id']}.txt"
            if not output_path.exists():
                fail(f"output file missing: {output_path}")
            scores.append(score_case(data, output_path.read_text(encoding="utf-8")))

    return 0 if print_scores(scores, args.json) else 1


if __name__ == "__main__":
    raise SystemExit(main())
