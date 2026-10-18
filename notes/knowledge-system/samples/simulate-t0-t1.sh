#!/usr/bin/env bash
# 扮演 AI 工具（宿主），按真实顺序调用 teamai 的 hook，复现 T0（记账）和 T1（打分提醒）。
# 用法：bash simulate-t0-t1.sh [sessionId]
set -euo pipefail
S=$(cd "$(dirname "$0")" && pwd)
export HOME="$S/alice"                 # 隔离：teamai 只认 $HOME/.teamai
SID="${1:-alice-live-$(date +%s)}"
T="$S/transcript-$SID.jsonl"           # 宿主自己的对话记录（Claude JSONL 格式）
: > "$T"

hook() {  # hook <event> <payload-json> [matcher]
  if [ -n "${3:-}" ]; then
    echo "$2" | teamai hook-dispatch "$1" --tool claude --matcher "$3" --stdin
  else
    echo "$2" | teamai hook-dispatch "$1" --tool claude --stdin
  fi
}
base() { echo "\"session_id\":\"$SID\",\"cwd\":\"$S\",\"transcript_path\":\"$T\""; }

echo "== T0-1 用户提交第一条 prompt"
hook prompt-submit "{$(base),\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"帮我修复 K8s pod 启动超时\"}"
echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"帮我修复 K8s pod 启动超时"}]}}' >> "$T"

echo "== T0-2 AI 调用 16 次工具（其中 5 次报错）"
tools=(Read Bash Edit Grep Bash Read Edit Bash Write Bash Read Grep Bash Edit Bash Read)
for i in "${!tools[@]}"; do
  tool=${tools[$i]}
  hook post-tool-use "{$(base),\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"$tool\",\"tool_input\":{},\"tool_response\":{}}" >/dev/null
  if [ $((i % 3)) -eq 1 ] && [ "$i" -lt 15 ]; then   # 第 1/4/7/10/13 次报错
    echo "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t$i\",\"is_error\":true,\"content\":\"Error: pod not ready\"}]}}" >> "$T"
  fi
done

echo "== T0-3 用户按 ESC 打断一次"
echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}' >> "$T"

echo "== T1 一轮结束：Stop"
hook stop "{$(base),\"hook_event_name\":\"Stop\"}"
echo
echo "== 结果"
echo "sessionId=$SID"
echo "-- events.jsonl 里本会话的事件数：$(grep -c "\"$SID\"" "$HOME/.teamai/dashboard/events.jsonl" || true)"
echo "-- 会话状态："
cat "$HOME/.teamai/sessions/$SID.json" 2>/dev/null || echo "(无)"
