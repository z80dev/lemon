defmodule LemonChannels.Adapters.Discord.SlashCommands do
  @moduledoc """
  Discord slash-command schema definitions for the Lemon adapter.

  Pure data: the `@*_command` maps describe each application command exactly as
  registered with Discord via `Nostrum.Api.ApplicationCommand`. Extracted from
  `LemonChannels.Adapters.Discord.Transport` so the transport GenServer holds
  orchestration only; the transport re-exports `slash_commands/0` and the
  `*_command_schema/0` accessors as thin delegations to preserve its public API.
  """

  # Discord slash commands
  @lemon_command %{
    name: "lemon",
    description: "Run a Lemon prompt",
    type: 1,
    options: [
      %{type: 3, name: "prompt", description: "Prompt text", required: true}
    ]
  }

  @session_command %{
    name: "session",
    description: "Session controls",
    type: 1,
    options: [
      %{
        type: 1,
        name: "new",
        description: "Start a new session",
        options: [
          %{type: 3, name: "project", description: "Project path or ID", required: false}
        ]
      },
      %{type: 1, name: "info", description: "Show session info"}
    ]
  }

  @model_command %{
    name: "model",
    description: "Choose AI model for this chat",
    type: 1
  }

  @thinking_command %{
    name: "thinking",
    description: "Set thinking level",
    type: 1,
    options: [
      %{
        type: 3,
        name: "level",
        description: "Thinking level",
        required: false,
        choices: [
          %{name: "off", value: "off"},
          %{name: "minimal", value: "minimal"},
          %{name: "low", value: "low"},
          %{name: "medium", value: "medium"},
          %{name: "high", value: "high"},
          %{name: "xhigh", value: "xhigh"},
          %{name: "clear", value: "clear"},
          %{name: "status", value: "status"}
        ]
      }
    ]
  }

  @reasoning_command %{
    @thinking_command
    | name: "reasoning",
      description: "Alias for /thinking"
  }

  @resume_command %{
    name: "resume",
    description: "Switch to a previous session",
    type: 1,
    options: [
      %{type: 3, name: "selector", description: "Session number or resume token", required: false}
    ]
  }

  @redirect_command %{
    name: "redirect",
    description: "Redirect the active run with a correction",
    type: 1,
    options: [
      %{type: 3, name: "correction", description: "Corrected instruction", required: true}
    ]
  }

  @queue_command %{
    name: "queue",
    description: "Queue a follow-up prompt behind the active run",
    type: 1,
    options: [
      %{type: 3, name: "prompt", description: "Follow-up prompt", required: true}
    ]
  }

  @q_command %{
    @queue_command
    | name: "q",
      description: "Alias for /queue"
  }

  @steer_command %{
    name: "steer",
    description: "Steer the active run with an additional instruction",
    type: 1,
    options: [
      %{type: 3, name: "prompt", description: "Steering instruction", required: true}
    ]
  }

  @cancel_command %{
    name: "cancel",
    description: "Cancel the current run",
    type: 1
  }

  @stop_command %{
    @cancel_command
    | name: "stop",
      description: "Alias for /cancel"
  }

  @reset_command %{
    name: "reset",
    description: "Alias for /session new",
    type: 1,
    options: [
      %{type: 3, name: "project", description: "Project path or ID", required: false}
    ]
  }

  @checkpoint_command %{
    name: "checkpoint",
    description: "Inspect or restore Lemon checkpoints",
    type: 1,
    options: [
      %{
        type: 1,
        name: "status",
        description: "Show redacted checkpoint status"
      },
      %{
        type: 1,
        name: "events",
        description: "Show redacted checkpoint event history",
        options: [
          %{
            type: 4,
            name: "limit",
            description: "Maximum events to show",
            required: false,
            min_value: 1,
            max_value: 20
          }
        ]
      },
      %{
        type: 1,
        name: "diff",
        description: "Show a redacted checkpoint diff preview",
        options: [
          %{type: 3, name: "checkpoint_id", description: "Checkpoint id", required: true}
        ]
      },
      %{
        type: 1,
        name: "restore",
        description: "Restore a checkpoint",
        options: [
          %{type: 3, name: "checkpoint_id", description: "Checkpoint id", required: true},
          %{
            type: 5,
            name: "confirm",
            description: "Must be true to restore files",
            required: true
          }
        ]
      }
    ]
  }

  @rollback_command %{
    @checkpoint_command
    | name: "rollback",
      description: "Rollback Lemon checkpoint changes"
  }

  @goal_command %{
    name: "goal",
    description: "Show or set the current session goal",
    type: 1,
    options: [
      %{
        type: 1,
        name: "set",
        description: "Set the current session goal",
        options: [
          %{
            type: 3,
            name: "objective",
            description: "Goal objective",
            required: true
          },
          %{
            type: 4,
            name: "max_continuations",
            description: "Maximum automatic continuations before Lemon pauses",
            required: false,
            min_value: 0
          }
        ]
      },
      %{
        type: 1,
        name: "clear",
        description: "Clear the current session goal"
      },
      %{
        type: 1,
        name: "pause",
        description: "Pause the current session goal"
      },
      %{
        type: 1,
        name: "resume",
        description: "Resume the current session goal"
      },
      %{
        type: 1,
        name: "continue",
        description: "Submit one continuation for the current session goal",
        options: [
          %{
            type: 4,
            name: "max_continuations",
            description: "Maximum automatic continuations before Lemon pauses",
            required: false,
            min_value: 0
          },
          %{
            type: 3,
            name: "model",
            description: "Worker model override",
            required: false
          }
        ]
      },
      %{
        type: 1,
        name: "loop_once",
        description: "Run one goal judge tick",
        options: [
          %{
            type: 3,
            name: "judge_model",
            description: "Judge model override",
            required: false
          },
          %{
            type: 3,
            name: "judge_failure_policy",
            description: "pause, continueOnce, or needsInput",
            required: false
          }
        ]
      },
      %{
        type: 1,
        name: "loop_start",
        description: "Start a bounded goal loop",
        options: [
          %{
            type: 5,
            name: "auto",
            description: "Persist auto scheduling until stopped or the goal pauses/completes",
            required: false
          },
          %{
            type: 4,
            name: "max_ticks",
            description: "Maximum judge ticks",
            required: false,
            min_value: 1
          },
          %{
            type: 4,
            name: "max_continuations",
            description: "Maximum automatic continuations before Lemon pauses",
            required: false,
            min_value: 0
          },
          %{
            type: 3,
            name: "judge_model",
            description: "Judge model override",
            required: false
          },
          %{
            type: 3,
            name: "judge_failure_policy",
            description: "pause, continueOnce, or needsInput",
            required: false
          }
        ]
      },
      %{
        type: 1,
        name: "loop_status",
        description: "Show the current goal loop"
      },
      %{
        type: 1,
        name: "loop_stop",
        description: "Stop the current goal loop"
      },
      %{
        type: 1,
        name: "status",
        description: "Show the current session goal"
      }
    ]
  }

  @kanban_command %{
    name: "kanban",
    description: "Manage durable Lemon kanban boards",
    type: 1,
    options: [
      %{
        type: 1,
        name: "boards",
        description: "List kanban boards",
        options: [
          %{type: 3, name: "status", description: "Board status", required: false},
          %{type: 3, name: "owner", description: "Board owner", required: false},
          %{
            type: 4,
            name: "limit",
            description: "Maximum boards to show",
            required: false,
            min_value: 1
          }
        ]
      },
      %{
        type: 1,
        name: "create",
        description: "Create a kanban board",
        options: [
          %{type: 3, name: "name", description: "Board name", required: true},
          %{type: 3, name: "workspace", description: "Workspace path", required: false}
        ]
      },
      %{
        type: 1,
        name: "show",
        description: "Show redacted board tasks",
        options: [
          %{type: 3, name: "board_id", description: "Board id", required: true},
          %{
            type: 4,
            name: "limit",
            description: "Maximum tasks to show",
            required: false,
            min_value: 1
          }
        ]
      },
      %{
        type: 1,
        name: "archive",
        description: "Archive a kanban board",
        options: [
          %{type: 3, name: "board_id", description: "Board id", required: true}
        ]
      },
      %{
        type: 1,
        name: "task_create",
        description: "Create a board task",
        options: [
          %{type: 3, name: "board_id", description: "Board id", required: true},
          %{type: 3, name: "title", description: "Task title", required: true},
          %{type: 3, name: "priority", description: "Task priority", required: false},
          %{type: 3, name: "assignee", description: "Task assignee", required: false},
          %{type: 3, name: "worker_profile", description: "Worker profile", required: false}
        ]
      },
      %{
        type: 1,
        name: "task_update",
        description: "Update a board task",
        options: [
          %{type: 3, name: "task_id", description: "Task id", required: true},
          %{type: 3, name: "status", description: "Task status", required: false},
          %{type: 3, name: "priority", description: "Task priority", required: false},
          %{type: 3, name: "assignee", description: "Task assignee", required: false},
          %{type: 3, name: "worker_profile", description: "Worker profile", required: false}
        ]
      },
      %{
        type: 1,
        name: "comment",
        description: "Add a redacted task comment",
        options: [
          %{type: 3, name: "task_id", description: "Task id", required: true},
          %{type: 3, name: "body", description: "Comment body", required: true}
        ]
      },
      %{
        type: 1,
        name: "dispatch_start",
        description: "Start a board dispatcher",
        options: [
          %{type: 3, name: "board_id", description: "Board id", required: true},
          %{
            type: 4,
            name: "max_concurrency",
            description: "Maximum concurrent tasks",
            required: false,
            min_value: 1
          },
          %{type: 3, name: "worker_profile", description: "Worker profile", required: false}
        ]
      },
      %{
        type: 1,
        name: "dispatch_status",
        description: "Show board dispatcher status",
        options: [
          %{type: 3, name: "board_id", description: "Board id", required: true}
        ]
      },
      %{
        type: 1,
        name: "dispatch_stop",
        description: "Stop a board dispatcher",
        options: [
          %{type: 3, name: "board_id", description: "Board id", required: true}
        ]
      }
    ]
  }

  @media_command %{
    name: "media",
    description: "Inspect redacted Lemon media jobs",
    type: 1,
    options: [
      %{
        type: 1,
        name: "status",
        description: "Show redacted media job status"
      }
    ]
  }

  @trigger_command %{
    name: "trigger",
    description: "Control message trigger mode",
    type: 1,
    options: [
      %{
        type: 3,
        name: "mode",
        description: "Trigger mode",
        required: false,
        choices: [
          %{name: "mentions", value: "mentions"},
          %{name: "all", value: "all"},
          %{name: "clear", value: "clear"},
          %{name: "status", value: "status"}
        ]
      }
    ]
  }

  @cwd_command %{
    name: "cwd",
    description: "Set working directory",
    type: 1,
    options: [
      %{type: 3, name: "path", description: "Project path, ID, or 'clear'", required: false}
    ]
  }

  @reload_command %{
    name: "reload",
    description: "Recompile code (dev only)",
    type: 1
  }

  @topic_command %{
    name: "topic",
    description: "Create a new thread or forum post",
    type: 1,
    options: [
      %{type: 3, name: "name", description: "Thread/post name", required: true},
      %{type: 3, name: "message", description: "Initial message content", required: false}
    ]
  }

  @file_command %{
    name: "file",
    description: "File operations",
    type: 1,
    options: [
      %{
        type: 1,
        name: "put",
        description: "Upload an attached file to the project",
        options: [
          %{type: 11, name: "attachment", description: "File to upload", required: true},
          %{type: 3, name: "path", description: "Destination path (relative)", required: false},
          %{type: 5, name: "force", description: "Overwrite existing file", required: false}
        ]
      },
      %{
        type: 1,
        name: "get",
        description: "Download a file from the project",
        options: [
          %{type: 3, name: "path", description: "File path (relative)", required: true}
        ]
      }
    ]
  }

  def slash_commands do
    [
      @lemon_command,
      @session_command,
      @model_command,
      @thinking_command,
      @reasoning_command,
      @resume_command,
      @redirect_command,
      @queue_command,
      @q_command,
      @steer_command,
      @cancel_command,
      @stop_command,
      @reset_command,
      @checkpoint_command,
      @rollback_command,
      @goal_command,
      @kanban_command,
      @media_command,
      @trigger_command,
      @cwd_command,
      @reload_command,
      @topic_command,
      @file_command
    ]
  end

  def redirect_command_schema, do: @redirect_command
  def kanban_command_schema, do: @kanban_command
  def checkpoint_command_schema, do: @checkpoint_command
  def rollback_command_schema, do: @rollback_command
  def media_command_schema, do: @media_command
end
