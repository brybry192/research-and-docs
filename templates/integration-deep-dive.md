---
topic: <integration name>
date: <YYYY-MM-DD>
source_repos:
  - https://github.com/...
tags: [go, newrelic, integrations]
status: draft
---

# \<Integration Name\> — Deep Dive Study Guide

**Repository:** \<URL\>  
**License:** \<MIT | Apache-2.0\>  
**Latest:** \<version\>  
**Language:** Go \<version\>

---

## Table of Contents

1. [Repository Layout](#1-repository-layout)
2. [Key Dependencies](#2-key-dependencies)
3. [Code Flow](#3-code-flow)
4. [Testing Approach](#4-testing-approach)
5. [Configuration Best Practices](#5-configuration-best-practices)
6. [Concerns and Improvement Areas](#6-concerns-and-improvement-areas)
7. [Reference Links](#7-reference-links)

---

## 1. Repository Layout

```
<integration-name>/
├── src/
│   ├── main.go          ← entry point
│   └── ...
├── tests/               ← integration tests
├── legacy/              ← definition.yml
├── go.mod / go.sum
├── Makefile
└── <name>-config.yml.sample
```

---

## 2. Key Dependencies

| Dependency | Role |
|---|---|
| `infra-integrations-sdk/v3` | Core SDK — entity model, metric types, args, JSON publish |
| `stretchr/testify` | Test assertions |
| ... | ... |

---

## 3. Code Flow

### 3.1 Entry Point

```
main()
  └─ integration.New(name, version)
  └─ sdk.ParseFlags(args)
  └─ ...
  └─ integration.Publish()
```

### 3.2 Connection Layer

*Describe how the integration connects to the target service.*

### 3.3 Data Collection

*Describe the queries, commands, or API calls used.*

### 3.4 Metric Population

*Describe how raw results map to SDK entities and metric sets.*

### 3.5 Inventory Collection

*Describe what inventory is collected and how.*

---

## 4. Testing Approach

### 4.1 Unit Tests

*How are DB/service interactions mocked? What libraries?*

### 4.2 Integration Tests

*Docker? Real service? Schema validation?*

### 4.3 Gaps

> ⚠️ **Note any missing coverage here.**

---

## 5. Configuration Best Practices

> ✅ *Note good patterns the integration demonstrates.*

- ...

---

## 6. Concerns and Improvement Areas

> ⚠️ **Concern:** *Describe the issue, its impact, and a suggested fix.*

> ⚠️ **Concern:** ...

---

## 7. Reference Links

| Resource | URL |
|---|---|
| GitHub repo | \<url\> |
| pkg.go.dev | \<url\> |
| Official docs | \<url\> |
| go.mod | \<url\> |
