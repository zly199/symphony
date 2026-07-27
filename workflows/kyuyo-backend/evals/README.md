# AI Evals

本目录用于验证项目级 AI 行为是否符合 `ai-workspace/governance/` 的规则。

## 目录职责

- `cases/`：评估用例，每个 YAML 描述输入、期望行为、硬检查、阻断失败和语义 rubric。
- `outputs/`：待评分的模型输出文本，默认文件名为 `<case-id>.txt`。
- `runners/`：执行器。
- `reports/`：评估结果报告。

## 执行方式

真实调用模型执行 case、保存输出并评分：

```bash
OPENAI_API_KEY=... python3 workflows/kyuyo-backend/evals/runners/run_evals.py run \
  --case 2026-06-ticket-html-workflow \
  --model gpt-5
```

批量执行全部 case：

```bash
OPENAI_API_KEY=... python3 workflows/kyuyo-backend/evals/runners/run_evals.py run \
  --model gpt-5 \
  --outputs-dir workflows/kyuyo-backend/evals/outputs \
  --report workflows/kyuyo-backend/evals/reports/latest.json
```

只校验 eval 资产结构：

```bash
python3 workflows/kyuyo-backend/evals/runners/run_evals.py validate
```

对 `outputs/` 下的模型输出做硬检查评分：

```bash
python3 workflows/kyuyo-backend/evals/runners/run_evals.py score --outputs-dir workflows/kyuyo-backend/evals/outputs
```

对单个 case 和单个输出评分：

```bash
python3 workflows/kyuyo-backend/evals/runners/run_evals.py score \
  --case 2026-06-ticket-html-workflow \
  --output workflows/kyuyo-backend/evals/outputs/2026-06-ticket-html-workflow.txt
```

输出 JSON 报告：

```bash
python3 workflows/kyuyo-backend/evals/runners/run_evals.py score \
  --outputs-dir workflows/kyuyo-backend/evals/outputs \
  --json > workflows/kyuyo-backend/evals/reports/latest.json
```

## 评分口径

- `must_include` 全部命中且 `must_not_include` 全部未命中，硬检查通过。
- 出现 `must_not_include` 内容，硬检查失败。
- `semantic_rubric` 和 `blocking_failures` 会输出到报告中，供人工或后续 LLM judge 复核。

## 运行说明

- `run` 会调用 OpenAI 模型，需要环境变量 `OPENAI_API_KEY`。
- 默认模型为 `gpt-5`，可通过 `--model` 或 `OPENAI_EVAL_MODEL` 覆盖。
- `run` 会把模型输出写入 `outputs/<case-id>.txt`，再执行与 `score` 相同的硬检查。
