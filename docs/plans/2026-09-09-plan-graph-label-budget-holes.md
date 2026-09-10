```mermaid
flowchart TD
  subgraph outside["outside the repository"]
    grammar(["mermaid flowchart grammar"])
    planner(["a planning agent"])
  end
  subgraph repo["this repository"]
    checker["<b>c1 · bin/check-plan-graph.py</b> · CHANGE<br/>tailed openers from one rule<br/>keyword-named node ids measured<br/><i>opus · high</i>"]
    skill["<b>c2 · skills/graphplan/SKILL.md</b> · CHANGE<br/>budget number typed nowhere<br/><i>sonnet</i>"]
    test["<b>c3 · tests/test-plan-graphs-are-terse.sh</b> · CHANGE<br/>fixtures: ==, tailed, keyword id<br/>drift guard on typed budget<br/><i>sonnet</i>"]
    plans[("docs/plans/*.md")]
    runall["tests/run-all.sh"]
    brief["skills/board/brief.py"]
  end
  checker -->|models| grammar
  planner -->|"runs on its plan"| checker
  brief -->|"names in prompt"| checker
  test -->|drives| checker
  test -->|reads| plans
  test -.->|"greps for typed budget"| skill
  skill -.->|"quotes --limits"| checker
  runall -->|runs| test
```
