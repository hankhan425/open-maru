@id("steward:editor")
permit(principal in Circle::"core",
       action in [Action::"ClaimTask", Action::"CreateTask", Action::"PostEvidence", Action::"PostGoalEvidence",
                  Action::"ReportMetric", Action::"ReviewTask", Action::"CancelTask", Action::"PauseGoal",
                  Action::"ResumeGoal", Action::"RequestClose", Action::"ManageSecrets"],
       resource == Goal::"editor");

@id("steward-session:editor:builder")
permit(principal in Circle::"core", action == Action::"StartSession", resource == Agent::"builder")
when { context.goal == "editor" };

@id("mandate:editor:agent:builder:caps")
permit(principal == Agent::"builder",
       action in [Action::"ClaimTask", Action::"PostEvidence", Action::"PostGoalEvidence"],
       resource == Goal::"editor")
when { context.now_epoch < 1798761600 };

@id("mandate:editor:agent:builder:metrics")
permit(principal == Agent::"builder", action == Action::"ReportMetric", resource == Goal::"editor")
when { ["weekly_active_users"].contains(context.metric) && context.now_epoch < 1798761600 };

@id("mandate:editor:agent:builder:spend:llm")
permit(principal == Agent::"builder", action == Action::"Spend", resource == Goal::"editor")
when { context.category == "llm" && context.amount_micros <= 25000000 && context.now_epoch < 1798761600 };

@id("mandate:editor:agent:builder:spend:compute")
permit(principal == Agent::"builder", action == Action::"Spend", resource == Goal::"editor")
when { context.category == "compute" && context.amount_micros <= 25000000 && context.now_epoch < 1798761600 };

@id("mandate:editor:person:jo:caps")
permit(principal == Person::"jo",
       action in [Action::"ClaimTask", Action::"CreateTask", Action::"PostEvidence", Action::"PostGoalEvidence"],
       resource == Goal::"editor");

@id("mandate:editor:person:jo:spend:expense")
permit(principal == Person::"jo", action == Action::"Spend", resource == Goal::"editor")
when { context.category == "expense" };

@id("editor:r_866679bf") @approval("editor:r_866679bf")
forbid(principal, action == Action::"Spend", resource == Goal::"editor")
when { context.amount_micros > 500000000 }
unless { context.approved_rules.contains("editor:r_866679bf") };

@id("editor:r_91607479") @approval("editor:r_91607479")
forbid(principal, action == Action::"Spend", resource == Goal::"editor")
when { context.category == "expense" }
unless { context.approved_rules.contains("editor:r_91607479") };

@id("operator:builder")
permit(principal == Person::"mina",
       action in [Action::"IssueToken", Action::"StartSession"],
       resource == Agent::"builder");

@id("self:jo")
permit(principal == Person::"jo", action == Action::"IssueToken", resource == Person::"jo");
