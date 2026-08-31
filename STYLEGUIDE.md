# Styleguide

Every agent that writes code here reads this file first. `board.toml` names it in
`docs.required`, so the build prompt points at it on every card.

**One file on purpose.** An index, a directory of guides, and a rule about which
guide wins are all overhead for a set nobody has read yet. Split this file when
it stops being readable, and not before.

**What this file never covers.** Line length, import order, quote style,
spacing, trailing commas. A formatter owns those. A reviewer who spends a finding
on one has spent a review round on something `ruff --fix` does for free.

**When two rules seem to disagree**, choose the version a stranger reads
correctly on the first pass.

---

## 1. Writing English

This governs every document here: this file, code comments, commit messages,
pull request bodies, specs and plans.

- **One idea per sentence.** Around twenty words. A sentence that needs a second
  clause to stay true is two sentences.
- **Active voice, present tense.**
- **Common words.** `use`, not `utilise`. `before`, not `prior to`.
- **Conclusion first, then the reason.** A reader who stops after one sentence
  should still have the answer.
- **Name the thing.** Give the path, the value, the command. Do not describe it
  and leave the reader to find it.
- **One term per concept.** Pick the word and reuse it. A synonym reads as a
  second thing.
- **Prefer bullets to paragraphs.** Three or more parallel points are a list. A
  paragraph earns its place when it carries an argument a list would break.
- **No hedging. No `simply`, `just` or `obviously`.** They tell a stuck reader
  that they are stupid.
- **Write for a reader whose first language is not English.**
- **Short does not mean thin.** State the failure a rule prevents. Name the
  incident where there was one. Say it in short sentences.

## 2. Simplicity

Readability is the goal. Every other rule in this file is a proxy for it.

- **The stranger test.** Would someone who has never seen this file read it
  correctly the first time? That question settles disagreements.
- **Complexity raises a question. It does not fail a build.** A flat twelve-branch
  dispatch table scores worse than a four-deep nest and reads far better, so the
  raw count is the weakest signal. Nesting depth and the number of reasons a unit
  has to change matter more.
- **Answer the question in the pull request** when a function passes ten
  branches, three levels of nesting, or four parameters.
- **Guard clauses over nesting.** Return early. The happy path stays at one
  indent.
- **Dispatch tables over `if`-chains.** A chain that maps a value to a behaviour
  is a table in disguise.
- **Extract a named predicate.** A condition that needs a comment to be read is a
  function that needs a name.
- **Polymorphism over a repeated conditional.** The same `switch` in three places
  is one type asking to exist.
- **A boolean parameter is usually two functions sharing one name.** `f(x, true)`
  tells the reader nothing at the call site.
- **YAGNI.** An abstraction you do not need is a cost. Everyone who reads past it
  pays.
- **Deleting beats simplifying.** The simplest version of a thing is often its
  absence.

## 3. Code standards

- **A name says what the thing is.** A name that needs a comment is the wrong
  name.
- **Comments carry reasoning. They never restate the code.** The code says what.
  A comment exists for what the code cannot say.
- **A comment records the failure that produced the rule.** Give the date and the
  evidence where there was any. Put it where someone would otherwise reintroduce
  the problem.
- **Refuse rather than degrade.** An unhandled case is an error, not a default.
  `bin/contract.py` is the worked example: a wrong-typed ancestor, an unrecognised
  key and an empty required value all refuse. A config that says less than its
  author thought, and says it with exit code 0, is worse than one that fails to
  load.
- **An error names what failed and what was expected.**
- **Never swallow an error.** A broad `catch` that keeps going turns a loud
  failure into a wrong answer.
- **One fact, one place.** Derive the second copy. Two copies do not drift
  immediately, and that delay is what makes the failure expensive.
- **Magic values get names.**
- **Delete dead code. Do not comment it out.** Git remembers. The reader does not
  know the commented block is dead.
- **Size is a signal, not a limit.** A long function raises a question about
  responsibility. Answer it in the pull request.
- **A dependency is permanent.** Prefer what is already here. Every future
  install, audit and upgrade pays, and the people paying did not choose it.
- **A unit computes or mutates, never both.** A function whose return value is
  useful and whose call also changes the world cannot be tested at one level.

## 4. Design

- **A unit has one purpose and one reason to change.**
- **You can say what a unit does, how to use it, and what it depends on without
  reading its internals.** If you cannot, the boundary is wrong.
- **Single responsibility.** Two reasons to change means two callers' changes
  collide.
- **Open-closed.** The third conditional is a design signal. Extend by adding,
  not by editing what already works.
- **Substitution.** A subtype that surprises the caller is a lie. The caller's
  contract is with the base.
- **Interface segregation.** A fat interface forces fake implementations. Every
  `NotImplementedError` in a subclass is this rule breaking.
- **Dependency inversion.** Depend on the shape you need, not on the thing that
  provides it. Policy does not import infrastructure.
- **Composition over inheritance.** Use inheritance only for genuine
  substitutability.
- **Parse at the edge. Keep the core pure.** Validate once, at the boundary.
  Everything inside may then trust its types.

**When a class is the wrong answer.** These rules describe forces, not ceremony,
and they apply to modules and functions as much as to classes.

- No state and one method is a function.
- A name ending in `Manager`, `Helper` or `Util` means the author could not say
  what the thing was.
- A two-line function does not need a factory.

## 5. Testing

- **Test at the highest level that can prove the claim.**
- **Implementation-pinning tests block refactoring.** A repository with dense unit
  tests cannot be reshaped. Every structural change reds a hundred tests that
  assert *how* it worked, so the cheapest path becomes bolting a fourth flag onto
  the existing shape. End-to-end tests survive a refactor by construction.
- **A unit test has to earn its place.** It earns it for dense edge-case logic,
  parsers and algorithms. It never earns it for wiring, delegation or a getter.
- **One test per behaviour, named as a sentence that claims it.** If two tests
  would share a name, there is one test. `tests/` here is the example:
  `test-evidence-reads-are-fresh`, `test-sweep-is-instance-scoped`.
- **Stub at the external boundary. Run everything inside for real.**
  `tests/lib/curl-stub.sh` and `tests/lib/linear-stub.py` are the worked example.
  This is what makes end-to-end tests affordable instead of slow or fake.
- **Never assert on a mock.** A test that verifies a stub was called is green by
  construction and proves nothing.
- **Tests are a budget, not a score.** Every test is permanent maintenance and
  permanent refactor friction. Coverage is a signal and never a target.
- **A bug fix ships the test that reproduces the bug**, at the level the bug
  occurred.
- **Delete a test that cannot name the failure it prevents.**
- **Localisation comes from the name, not the level.** If a failure would not tell
  you what behaviour broke, the test is badly named. It is not too coarse.
- **The suite runs on every pull request.** `test.command` runs on every build
  attempt and again in CI, so slowness is a property of the loop.

## 6. Python

The formatter owns layout. This section never mentions it.

- **Type the boundaries, not every local.** Public functions and module edges
  carry annotations. A local whose type is obvious from its assignment does not.
- **Model states with dataclasses, enums and unions.** A dict with six keys, four
  of them sometimes absent, is a type nobody wrote down.
- **Use specific exceptions.** Never a bare `except`. Never `except: pass`.
- **Keep imports pointing one way.** A cycle is the dependency rule failing out
  loud.
- **Context managers own resources.**
- **No mutable default arguments.**
- **A comprehension that needs two clauses is a loop.**
- **pytest shape.** Plain `assert`. Fixtures instead of `setUp`. `parametrize`
  instead of copy-paste.
- **`pathlib` over `os.path`. f-strings over `%` and `.format`.**

## 7. TypeScript

- **Turn `strict` on. `any` is a bug. Use `unknown` at the boundary.**
- **Discriminated unions over boolean flags and optional soup.** Four optional
  fields encode sixteen states. Three of them are legal.
- **Parse once at the boundary so the types stop lying.** A type asserted over
  unvalidated input is a comment with syntax highlighting.
- **`as` is an unverifiable claim.** It is never a way to silence the compiler.
  The same is true of `!`.
- **One representation of absent, chosen across the project.** `null` or
  `undefined`. Not both.
- **Errors are typed and never swallowed.** An empty `catch` is the swallowing
  rule in TypeScript costume.
- **No floating promises. State the concurrency.** Sequential `await` in a loop
  and `Promise.all` are different decisions. The reader must be able to tell which
  one was made.
- **A module's exports are its public API.** Do not import another module's
  internals.
- **`readonly` by default.**

## 8. React

- **Derive state. Do not store it.** Two pieces of state that must agree are a bug
  waiting for a race.
- **Effects synchronise with the outside world. They never compute.** If render
  can compute it, it is not an effect.
- **Component boundaries follow the data, not the visual nesting.**
- **Eight boolean props means several components.**
- **Keys are identity. Never the index.**
- **Components do not own the network.**
- **Hooks encapsulate behaviour, not lines.** Never call a hook conditionally.
- **Colocate state as low as it can live.** Lift it only when it is genuinely
  shared.
- **Semantic elements first.**
- **One styling approach per project, declared.**

## 9. Review

- **Severity is a promise.** `blocking` stops the build and sends it back.
  `warning` and `note` are recorded and stop nothing.
- **`blocking` requires a concrete, reproducible failure path.** Name specific
  inputs or state that produce a wrong result. A finding nobody can reproduce
  costs a review round for nothing.
- **An empty findings list is a valid and useful answer.**
- **No inflation, and no promotion by co-detection.** Several reviewers noticing
  one thing is one finding, not a more severe one. Independent detection is
  evidence a finding is real, not evidence it is worse.
- **One finding per defect.**
- **A later round judges the diff in front of it.** The previous round's findings
  are not evidence about this one.

**What is not a finding.**

- Style this file does not cover.
- Preference.
- Hypothetical inputs the code cannot receive.
- "Could be faster" with no measurement.
- Something a test already covers.
- Anything the ticket explicitly excluded.

**When you think a blocking finding is wrong.**

- **Read fresh evidence, not the working tree.** `evidence.sh` fetches, then
  answers. `git show origin/main:<path>` reads a local ref that no fetch is
  guaranteed to have refreshed.
- **Reproduce the stated failure path.** A finding whose path does not reproduce
  is refuted. A finding with no path was already invalid.
- **Say so in a pull request comment before touching any code.** Then stop. Do not
  edit, and do not silently ignore it either.

## 10. Name nothing outside this repository

- **Every fact about a project, a machine or a person is read at runtime**, from
  `board.toml` or from instance state.
- **Never hardcode an id.** `bin/resolve-ids.py` resolves team, project, state and
  label ids once and pins them in `ids.env`. An id written into a document is
  wrong for every installation but the one it was copied from.
- **A repository that names another project is not a template.** It is a fork with
  the names left in.
- `tests/test-nothing-outside-this-repository-is-named.sh` enforces this.

## 11. When you are not sure

- **Finish everything that does not depend on the ambiguity first.** A report that
  also delivers eight of ten things beats a question asked at minute one.
- **Prefer proceeding under a stated assumption.** Write the assumption down. Stop
  only when no assumption would be safe.
- **The environment is not the card.** No disk, a quota, a missing credential, a
  network failure: stop and say exactly that. Name the command. Quote the error.
  Do not route around it. The machine can be repaired and you can be re-run for
  free. A build that works around a broken environment and then dies costs the
  ticket one of its few attempts.
- **The most expensive artefact here is a large, confident, wrong pull request.**
  It consumes reviewers and a fix round before anyone notices the card was the
  problem.
