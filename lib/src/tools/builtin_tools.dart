import '../core/cancellation.dart';
import 'tool.dart';

/// Lets the model ask the user a question and wait for the answer.
///
/// The runner turns the call into a `UserInputRequested` event; the host
/// answers with `AgentRun.respond`. Waiting time is excluded from the
/// wall-clock budget.
class AskUserTool extends HarnessTool {
  const AskUserTool();

  @override
  String get name => 'ask_user';

  @override
  String get description =>
      'Ask the user a question when you cannot proceed without their input '
      '(missing details, a choice between options, or confirmation). The '
      'user answers in a popup and the answer is returned as the tool '
      'result. Pass `choices` for a single choice (["Yes", "No"] for a '
      'yes/no question). To collect several details at once, pass `fields` '
      '(one popup with all of them); the answer is then a JSON object '
      'keyed by field id. Do not use it for questions you can answer '
      'yourself or with other tools.';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'question': {'type': 'string', 'description': 'The question to show.'},
      'choices': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': 'Optional answer options to offer.',
      },
      'fields': {
        'type': 'array',
        'maxItems': maxFields,
        'description':
            'Optional: several details to collect in one popup. Use '
            'instead of `choices` when you need more than one answer.',
        'items': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': 'Key in the answer.'},
            'label': {'type': 'string', 'description': 'Shown to the user.'},
            'type': {
              'type': 'string',
              'enum': ['text', 'number', 'choice', 'date', 'boolean'],
            },
            'choices': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'Options for a `choice` field.',
            },
            'required': {'type': 'boolean'},
            'placeholder': {'type': 'string'},
          },
          'required': ['id', 'label'],
        },
      },
    },
    'required': ['question'],
  };

  /// Most fields one question may ask for.
  static const int maxFields = 12;

  @override
  ToolAnnotations get annotations => ToolAnnotations.readOnlyLocal;

  @override
  String displayLabel(Map<String, Object?> input) => 'Waiting for your answer…';

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final question = (input['question'] as String? ?? '').trim();
    if (question.isEmpty) return ToolOutput.error('question must not be empty');
    final rawFields = input['fields'];
    if (rawFields is List && rawFields.isNotEmpty) {
      if (rawFields.length > maxFields) {
        return ToolOutput.error('fields: at most $maxFields fields');
      }
      final fields = <UserInputField>[];
      final ids = <String>{};
      for (final raw in rawFields) {
        final field = UserInputField.tryParse(raw);
        if (field == null) {
          return ToolOutput.error(
            'fields: each field needs a non-empty id and label',
          );
        }
        if (!ids.add(field.id)) {
          return ToolOutput.error('fields: duplicate id "${field.id}"');
        }
        fields.add(field);
      }
      final answer = await context.requestUserInput(
        question,
        inputType: 'form',
        fields: fields,
      );
      return ToolOutput.text(answer.isEmpty ? '(no answer)' : answer);
    }
    final rawChoices = input['choices'];
    final choices =
        rawChoices is List
            ? rawChoices.map((c) => '$c').where((c) => c.isNotEmpty).toList()
            : null;
    try {
      final answer = await context.requestUserInput(
        question,
        inputType: choices == null || choices.isEmpty ? 'text' : 'choice',
        choices: choices == null || choices.isEmpty ? null : choices,
      );
      return ToolOutput.text(answer.isEmpty ? '(no answer)' : answer);
    } on CancelledException {
      rethrow;
    }
  }
}

/// Status of a [Todo].
enum TodoStatus { pending, inProgress, completed }

/// One item of the run's todo list.
final class Todo {
  final String id;
  final String content;
  final TodoStatus status;
  const Todo({required this.id, required this.content, required this.status});

  Map<String, Object?> toJson() => {
    'id': id,
    'content': content,
    'status': switch (status) {
      TodoStatus.pending => 'pending',
      TodoStatus.inProgress => 'in_progress',
      TodoStatus.completed => 'completed',
    },
  };
}

/// Run-state key under which [TodoWriteTool] stores the list.
const todosRunStateKey = 'todos';

/// Lets the model plan multi-step work as a todo list it rewrites as it
/// goes (whole-list replacement). The list is returned on `RunResult.todos`
/// and can be seeded through `RunConfig.initialTodos`.
class TodoWriteTool extends HarnessTool {
  const TodoWriteTool();

  static const int maxTodos = 50;
  static const int maxContentChars = 500;

  @override
  String get name => 'todo_write';

  @override
  String get description =>
      'Create or update your task list for multi-step work. Send the FULL '
      'list every time (it replaces the previous one). Keep exactly one item '
      'in_progress while working; mark items completed as soon as they are '
      'done. Skip this tool for simple one-step requests.';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'todos': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string'},
            'content': {'type': 'string'},
            'status': {
              'type': 'string',
              'enum': ['pending', 'in_progress', 'completed'],
            },
          },
          'required': ['content', 'status'],
        },
      },
    },
    'required': ['todos'],
  };

  @override
  ToolAnnotations get annotations =>
      const ToolAnnotations(destructive: false, idempotent: true);

  @override
  String displayLabel(Map<String, Object?> input) => 'Updating the plan…';

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final raw = input['todos'];
    if (raw is! List) return ToolOutput.error('todos must be an array');
    if (raw.length > maxTodos) {
      return ToolOutput.error('At most $maxTodos todos are allowed.');
    }
    final todos = <Todo>[];
    for (var i = 0; i < raw.length; i++) {
      final item = raw[i];
      if (item is! Map) return ToolOutput.error('todos[$i] must be an object');
      final content = '${item['content'] ?? ''}'.trim();
      if (content.isEmpty) {
        return ToolOutput.error('todos[$i].content is empty');
      }
      if (content.length > maxContentChars) {
        return ToolOutput.error(
          'todos[$i].content exceeds $maxContentChars chars',
        );
      }
      final status = switch (item['status']) {
        'in_progress' => TodoStatus.inProgress,
        'completed' => TodoStatus.completed,
        _ => TodoStatus.pending,
      };
      final id = '${item['id'] ?? ''}'.trim();
      todos.add(
        Todo(
          id: id.isEmpty ? '${i + 1}' : id,
          content: content,
          status: status,
        ),
      );
    }
    context.runState[todosRunStateKey] = todos;
    final done = todos.where((t) => t.status == TodoStatus.completed).length;
    return ToolOutput(
      content: [
        ToolOutput.text(
          'Todo list updated ($done/${todos.length} completed).',
        ).content.first,
      ],
      structured: [for (final t in todos) t.toJson()],
    );
  }
}
