# StrangerTalks Language Team — Entrance Comprehension Study Protocol v1

Owner: Manvith  
Study design owner: Partner 01 — World Language & Meaning  
Interface implementation partner: Partner 02  
Governing measurement contract: `measurement-contract-v0.3.md`

## Purpose

This protocol freezes how the first qualitative entrance-language study will be run before participants are recruited and before results are visible.

The study asks a narrow question:

> Can a first-time person correctly understand what StrangerTalks is offering at the entrance, what each primary Door means, and what Talk Language controls, without being coached by the moderator?

This is not a satisfaction study, brand-liking study, or general usability audit.

## Minimum sample

Minimum scored sample:

# 24 first-time participants

The study may recruit extra participants to replace only legitimate predeclared exclusions.

Do not stop early because the first results look good or bad.

Do not add participants selectively to rescue one Door after looking at outcomes. A follow-up round must be declared separately.

## Participant eligibility

A scored participant must:

- be seeing the tested StrangerTalks entrance for the first time;
- not have contributed to StrangerTalks product/design/code decisions;
- not have been briefed on the intended meaning of the Four Doors;
- be able to communicate their interpretation in a language understood by the research process or an approved neutral interpreter;
- consent to participate in the product-comprehension exercise.

Do not require technical knowledge.

Do not recruit only people already familiar with Omegle-like products.

## Recruitment balance

The first round should seek ordinary internet users rather than a specialist panel.

Avoid overloading the sample with:

- software developers;
- designers;
- people who already know StrangerTalks;
- close collaborators who have heard the product pitch repeatedly.

If recruitment permits, include a mixture of people who primarily use mobile and desktop internet products.

Do not infer demographic meaning from Talk Language choice.

## Tested artifact

The study must use one frozen build/release reference.

Record:

- repository commit SHA;
- deployed build/release identifier if applicable;
- capture date;
- viewport/device class;
- exact entrance copy/labels visible in that build.

Do not mix materially different entrance versions inside one scored round.

If a production hotfix materially changes tested wording or hierarchy, stop the round and decide whether the remaining participants belong to a new round.

## Moderator law

The moderator must not explain the intended Door meanings before teach-back.

Forbidden leading prompts include:

- “Deep Talk means serious conversations, right?”
- “Vent is where you just want someone to listen.”
- “Advice means you want suggestions.”
- “Talk Language is not the website language.”

If a participant asks what a label means before answering, the moderator should use a neutral response such as:

> “Tell me what you think it means from what you see here.”

The goal is to test the interface, not the moderator’s teaching skill.

## Study sequence

### Stage 1 — unprompted entrance read

Show the frozen entrance without explanation.

Allow the participant to look naturally.

Do not point at any specific control or Door.

Ask:

> “What do you think you can do here?”

Record the answer as close to verbatim as practical.

### Stage 2 — primary choice

Ask:

> “If you were going to use this right now, what would you choose first, and why?”

This is behavioral/context evidence only. The chosen Door is not scored as correct or incorrect.

### Stage 3 — Four Door teach-back

For each visible Door, ask neutrally:

> “What do you think this would give you?”

or:

> “What kind of conversation would you expect if you chose this?”

Do not require dictionary-like wording.

Score meaning, not phrase matching.

### Stage 4 — contrast probes

Use neutral contrast questions where needed:

> “How is this different from the other choices?”

The moderator may ask for clarification but must not supply the answer.

### Stage 5 — Talk Language comprehension

Ask:

> “What do you think this language choice changes?”

Then:

> “What would you expect to stay the same if you changed it?”

The core distinction under test is whether the participant understands Talk Language as the language for the human interaction/conversation rather than automatically assuming it changes the whole StrangerTalks interface.

### Stage 6 — temporariness / identity promise

Using only what is visible in the tested entrance, ask:

> “What do you expect StrangerTalks to remember about you or this conversation?”

Do not promise privacy properties that the interface/product contract does not actually guarantee.

### Stage 7 — final confidence probe

Ask:

> “Was anything here unclear enough that it would make you hesitate before starting?”

This answer is diagnostic qualitative evidence and must not be converted into a causal metric without coding rules.

## Frozen Four Door answer key

### Deep Talk

Correct core intention:

- serious, meaningful, thoughtful, personal, or deeper human conversation;
- advice is not required.

Material misconception examples:

- treating it as professional expert counselling by default;
- treating it as the same thing as Advice;
- treating “deep” purely as long duration rather than conversation depth.

### Vent

Correct core intention:

- express what is on one’s mind;
- be heard/listened to;
- solutions or advice are not required.

Material misconception examples:

- assuming the other person must solve the problem;
- treating it as anger-only;
- treating it as a public post/feed rather than a conversation intention.

### Distract

Correct core intention:

- lighter human interaction used for diversion, relief, or a mental break;
- the person does not need to arrive with a serious topic.

Material misconception examples:

- assuming StrangerTalks will only show passive entertainment content with no human interaction;
- treating it as blocking/muting another user.

### Advice

Correct core intention:

- seek another person’s input, suggestion, perspective, or guidance.

Material misconception examples:

- treating it as merely venting with no desire for input;
- assuming professional/legal/medical expert status is guaranteed.

## Door scoring

Each Door receives one score per participant:

- `2` — correct core intention without material confusion;
- `1` — partial/ambiguous understanding or substantial overlap with a neighboring Door;
- `0` — materially wrong, absent, inverted, or assigned to another Door.

A Door passes the round only if:

- score-2 comprehension is at least 80%;
- direct confusion with any single neighboring Door is below 20%;
- no recurring critical misconception materially changes the expected experience.

Report raw counts with every percentage.

Example format:

`Deep Talk: 20/24 score-2 = 83.3%`

## General entrance rubric

Score each participant 0–2 on:

1. primary intention understood;
2. expected human/social experience understood;
3. Talk Language understood as human-talk context rather than whole-interface language;
4. temporariness/identity promise understood without stronger false guarantees.

Participant-level pass requires:

- at least `6/8`; and
- no critical misconception.

## Critical misconception definition

A critical misconception is not a small wording mismatch.

It is a misunderstanding likely to cause the person to enter expecting a materially different product or privacy/safety promise.

Examples may include:

- expecting verified professionals when none are promised;
- believing a Door guarantees a specific type of stranger rather than expressing conversation intent;
- believing Talk Language changes the entire interface when the tested product contract says it controls human conversation language;
- believing the product promises stronger anonymity/data deletion than it actually does.

Any new critical-misconception category discovered during scoring must be documented with examples. Do not retroactively redefine the answer key merely to improve pass rates.

## Independent scoring

Two independent raters score the teach-back answers using the frozen rubric.

Partner 01 and Partner 02 must not be the only unchallenged judges of language they designed.

The raters should score independently before discussing disagreements.

Record:

- Rater A score;
- Rater B score;
- disagreement type;
- adjudicated score if needed.

Target inter-rater agreement:

# Cohen’s kappa ≥ 0.70

If kappa is below `0.70`, the rubric is not considered sufficiently objective for a final language verdict.

In that case:

1. document disagreement patterns;
2. clarify the rubric without looking for a wording outcome to favor;
3. freeze the revised rubric;
4. rescore the round.

Do not simply average inconsistent raters and call the result objective.

## Predeclared participant exclusions

A recruited participant may be excluded from the scored sample only for reasons such as:

- they reveal prior substantive knowledge of the StrangerTalks design work;
- the tested build fails to load or materially breaks during the session;
- moderator error supplies/strongly leads the intended answer before teach-back;
- recording/notes are unusable enough that independent scoring is impossible;
- participant withdraws consent.

Do not exclude because:

- they dislike the product;
- they misunderstand a Door;
- they choose a surprising Door;
- they are slow;
- their answer hurts the pass rate.

Every exclusion must be listed with a bounded reason code and replacement status.

## Evidence handling

Store only what is needed for the research question.

The scored research artifact should prefer:

- participant study ID;
- first-time eligibility status;
- tested build SHA;
- device class;
- teach-back responses or faithful notes;
- rubric scores;
- rater disagreement/adjudication;
- bounded exclusion reason if applicable.

Do not attach unrelated personal profiles to the study record.

Do not infer sensitive characteristics from language choice or Door choice.

## Predeclared outcome categories

The round may conclude only:

### PASS

All required Door and general-comprehension thresholds pass, kappa threshold passes, and no unresolved recurring critical misconception exists.

### MIXED / REVISION REQUIRED

Some meaning works but one or more required thresholds fail or a recurring material misconception exists.

### INVALID STUDY

The procedure, tested artifact, recruitment/scoring integrity, or rater agreement is insufficient to support a verdict.

Do not call a study `PASS` because participants say they like the copy.

Do not call it `FAIL` merely because preferences differ.

## Required report

```text
STRANGERTALKS LANGUAGE TEAM — ENTRANCE COMPREHENSION ROUND

TESTED BUILD SHA:
TEST DATES:
RECRUITED N:
EXCLUDED N + REASONS:
SCORED N:

RATER A:
RATER B:
COHEN'S KAPPA:

DEEP TALK:
score 2 / score 1 / score 0
neighbor-confusion counts
critical misconceptions

VENT:
score 2 / score 1 / score 0
neighbor-confusion counts
critical misconceptions

DISTRACT:
score 2 / score 1 / score 0
neighbor-confusion counts
critical misconceptions

ADVICE:
score 2 / score 1 / score 0
neighbor-confusion counts
critical misconceptions

TALK LANGUAGE:
correct / partial / incorrect counts
recurring misconceptions

GENERAL ENTRANCE RUBRIC:
participant passes / scored N
critical misconceptions

UNPROMPTED ENTRANCE THEMES:
HESITATION THEMES:

VERDICT:
PASS / MIXED — REVISION REQUIRED / INVALID STUDY

EVIDENCE LIMITATIONS:
NEXT ACTION:
```

## Change-control law

Once participant 1 begins the scored round:

- do not change the tested wording mid-round;
- do not change scoring thresholds mid-round;
- do not change the answer key mid-round to rescue outcomes;
- do not change the minimum sample because recruitment is inconvenient.

A material protocol change creates a new study version or new round.

## Present state

Protocol frozen before the first scored participant.

Recruitment and study execution have not yet been proven or started under this protocol.
