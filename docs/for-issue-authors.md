# For people who write issues

This page is for everyone who asks for changes through GitHub issues — no
technical knowledge needed.

## What happens with your issue

1. A developer plans the work. Sometimes one issue becomes several pieces of work,
   sometimes several issues become one. Each piece is a **feature request (FR)**.
2. A comment appears on your issue, listing the FRs and their state. It updates
   itself as the work moves on.
3. When a piece is ready on the test environment, you may get a comment
   **"Ready for acceptance on …"** with a link. Please try it there and reply on
   the issue: either "OK", or what is not right yet.
4. Your issue is closed once **all** its FRs are done. A note on the issue says
   which ones.

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

Please never put passwords, personal data of customers or other confidential
information into an issue.

Handing over several issues at once? Give them a common label, milestone or
project, and say so — they can be planned together.

## Reading the comment on your issue

> **Feature requests for this issue**
>
> | FR | Title | Status | PR |
> |---|---|---|---|
> | FR-012 | Coupon field in checkout | merged | acme/shop#87 |
> | FR-013 | Discount line on invoice | in-review | acme/shop#91 |

| Status        | In plain words                                                                |
| ------------- | ----------------------------------------------------------------------------- |
| `open`        | planned, not started                                                          |
| `in-progress` | being built                                                                   |
| `in-review`   | built and tested — waiting for the final review, possibly for your acceptance |
| `merged`      | finished and part of the product's code                                       |
| `dropped`     | will not be done — ask the team why, if nobody has said so on the issue       |

**Merged does not always mean live.** When a change reaches your production
system depends on the project's release schedule — ask the team if it matters.

The comment is generated: changes you make to it are overwritten. Questions and
answers go into normal comments on the issue.
