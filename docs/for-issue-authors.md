# For people who write issues

This page is for everyone who asks for changes through GitHub issues — no
technical knowledge needed.

## What happens with your issue

1. A developer works it out together with Claude, with the code at hand, into a
   precise specification — a **feature request (FR)**:
   - often your issue **becomes** the FR: its description is replaced by the
     specification, and your original text is kept at its end (click *Original
     request*). You get a short comment when that happens;
   - if it needs several pieces of work, each one appears as a **sub-issue** of
     your issue, and your issue shows their progress;
   - if another FR covers it as well, that FR mentions your issue, and you see it
     in your issue's history.
2. Read the specification, especially **Acceptance criteria** — these are the
   checks the work is tested against. Something missing or wrong? Say so in a
   comment, the earlier the better.
3. When a piece is ready on the test environment, you may get a comment
   **"Ready for acceptance on …"** with a link. Please try it there and reply on
   the issue: either "OK", or what is not right yet.
4. An FR issue closes when its change is merged. Your issue is closed once
   **all** its FRs are done; a note says which ones.

## Writing a good issue

On GitHub choose **New issue → Feature request**. The form asks for:

- **Problem or need** — in your words, not as a solution.
- **Who is affected** — for example "customers paying by invoice", "all admins".
- **Desired behaviour** — steps, examples, a sketch or a screenshot.
- **How do we know it is done** — sentences someone can check: "I enter a coupon
  code and the total drops by 10 %." They become the checks the work is tested
  against, so they matter most.
- **Priority** — low, medium or high.
- **Size** — your estimate: a small change, a normal feature, something larger,
  or big and risky. "Don't know" is fine; the team adjusts it. It decides how much
  effort goes into the implementation.
- **Model** and **Effort** — leave them on "From size" unless you work on the
  technical side.

Rough is fine — the details are worked out with you. Please never put passwords,
personal data of customers or other confidential information into an issue.

Handing over several issues at once? Give them a common label, milestone or
project, and say so — they can be worked out together.

## Following your issue

| You see                            | It means                                                                       |
| ---------------------------------- | ------------------------------------------------------------------------------ |
| label `fr-request`                 | your request, waiting to be worked out                                         |
| label `fr`                         | a specified FR — ready to be built, or being built                             |
| a pull request under *Development* | the change is being finished; *Ready for acceptance* follows when it is tested |
| closed as *completed*              | done, and part of the product's code                                           |
| closed as *not planned*            | will not be done — the closing comment says why                                |

**Done does not always mean live.** When a change reaches your production system
depends on the project's release schedule — ask the team if it matters.

Questions and answers go into normal comments on the issue.
