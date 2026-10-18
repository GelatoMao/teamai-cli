---
title: "K8s pod 启动超时：startupProbe 阈值过小"
author: alice
date: 2026-10-18
tags: [k8s, troubleshooting, deployment]
---
## Context
Java 服务冷启动约 90s，pod 反复被 kill，CrashLoopBackOff。
## Solution
把 startupProbe.failureThreshold 从 3 调到 30（periodSeconds=10），livenessProbe 不变。
## Lessons
启动慢的服务用 startupProbe 兜底，不要靠加大 livenessProbe 的 initialDelaySeconds。
## Related Skills
kubectl describe pod / kubectl logs --previous
