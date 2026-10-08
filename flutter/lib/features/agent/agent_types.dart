library;

class AgentProject {
  final String path;

  final String name;

  final int sessions;

  final DateTime? lastUsed;

  const AgentProject({
    required this.path,
    required this.name,
    this.sessions = 0,
    this.lastUsed,
  });

  factory AgentProject.fromJson(Map<String, dynamic> json) => AgentProject(
    path: json['path']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    sessions: json['sessions'] is num ? (json['sessions'] as num).toInt() : 0,
    lastUsed: DateTime.tryParse(json['lastUsed']?.toString() ?? ''),
  );

  factory AgentProject.fromPath(String path) {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    return AgentProject(path: path, name: parts.isEmpty ? path : parts.last);
  }
}

class AgentSession {
  final String id;

  final String name;

  final int messages;

  final String provider;
  final String model;

  final String harness;
  final String harnessName;

  final String path;

  final String preview;

  final DateTime? startedAt;
  final DateTime? updatedAt;

  final bool busy;

  const AgentSession({
    required this.id,
    this.name = '',
    this.messages = 0,
    this.provider = '',
    this.model = '',
    this.harness = '',
    this.harnessName = '',
    this.path = '',
    this.preview = '',
    this.startedAt,
    this.updatedAt,
    this.busy = false,
  });

  factory AgentSession.fromJson(Map<String, dynamic> json) => AgentSession(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    messages: json['messages'] is num ? (json['messages'] as num).toInt() : 0,
    provider: json['provider']?.toString() ?? '',
    model: json['model']?.toString() ?? '',
    harness: json['harness']?.toString() ?? '',
    harnessName: json['harnessName']?.toString() ?? '',
    path: json['path']?.toString() ?? '',
    preview: json['preview']?.toString() ?? '',
    startedAt: DateTime.tryParse(json['startedAt']?.toString() ?? ''),
    updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? ''),
    busy: json['busy'] == true,
  );

  String get modelLabel => model.isEmpty ? '' : '$provider/$model';

  String get projectName {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    return parts.isEmpty ? '' : parts.last;
  }
}

class AgentSessionInfo {
  final String id;

  final String path;

  final String name;

  final String model;
  final String provider;

  final String modelName;

  final bool local;

  final String harness;
  final String harnessName;

  final bool contextEstimated;

  final int messages;

  final bool busy;

  final String thinkingLevel;

  final String effort;

  final int? contextTokens;
  final int? contextWindow;

  final double contextPercent;

  final int tokensInput;
  final int tokensOutput;
  final int tokensCacheRead;
  final int tokensTotal;
  final double cost;

  final int userMessages;
  final int assistantMessages;
  final int toolCalls;

  final DateTime? startedAt;
  final DateTime? updatedAt;

  final String sessionFile;

  const AgentSessionInfo({
    required this.id,
    required this.path,
    this.name = '',
    this.model = '',
    this.provider = '',
    this.modelName = '',
    this.local = false,
    this.harness = '',
    this.harnessName = '',
    this.contextEstimated = false,
    this.messages = 0,
    this.busy = false,
    this.thinkingLevel = '',
    this.effort = '',
    this.contextTokens,
    this.contextWindow,
    this.contextPercent = 0,
    this.tokensInput = 0,
    this.tokensOutput = 0,
    this.tokensCacheRead = 0,
    this.tokensTotal = 0,
    this.cost = 0,
    this.userMessages = 0,
    this.assistantMessages = 0,
    this.toolCalls = 0,
    this.startedAt,
    this.updatedAt,
    this.sessionFile = '',
  });

  AgentSessionInfo withName(String value) => AgentSessionInfo(
    id: id,
    path: path,
    name: value,
    model: model,
    provider: provider,
    modelName: modelName,
    local: local,
    harness: harness,
    harnessName: harnessName,
    contextEstimated: contextEstimated,
    messages: messages,
    busy: busy,
    thinkingLevel: thinkingLevel,
    effort: effort,
    contextTokens: contextTokens,
    contextWindow: contextWindow,
    contextPercent: contextPercent,
    tokensInput: tokensInput,
    tokensOutput: tokensOutput,
    tokensCacheRead: tokensCacheRead,
    tokensTotal: tokensTotal,
    cost: cost,
    userMessages: userMessages,
    assistantMessages: assistantMessages,
    toolCalls: toolCalls,
    startedAt: startedAt,
    updatedAt: updatedAt,
    sessionFile: sessionFile,
  );

  factory AgentSessionInfo.fromJson(Map<String, dynamic> json) {
    final tokens = json['tokens'] is Map
        ? (json['tokens'] as Map).cast<String, dynamic>()
        : const {};
    int? num_(Object? v) => v is num ? v.toInt() : null;
    return AgentSessionInfo(
      id: json['id']?.toString() ?? '',
      path: json['path']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      model: json['model']?.toString() ?? '',
      provider: json['provider']?.toString() ?? '',
      modelName: json['modelName']?.toString() ?? '',
      local: json['local'] == true,
      harness: json['harness']?.toString() ?? '',
      harnessName: json['harnessName']?.toString() ?? '',
      contextEstimated: json['contextEstimated'] == true,
      messages: num_(json['messages']) ?? 0,
      busy: json['busy'] == true,
      thinkingLevel: json['thinkingLevel']?.toString() ?? '',
      effort: json['effort']?.toString() ?? '',
      contextTokens: num_(json['contextTokens']),
      contextWindow: num_(json['contextWindow']),
      contextPercent: json['contextPercent'] is num
          ? (json['contextPercent'] as num).toDouble()
          : 0,
      tokensInput: num_(tokens['input']) ?? 0,
      tokensOutput: num_(tokens['output']) ?? 0,
      tokensCacheRead: num_(tokens['cacheRead']) ?? 0,
      tokensTotal: num_(tokens['total']) ?? 0,
      cost: json['cost'] is num ? (json['cost'] as num).toDouble() : 0,
      userMessages: num_(json['userMessages']) ?? 0,
      assistantMessages: num_(json['assistantMessages']) ?? 0,
      toolCalls: num_(json['toolCalls']) ?? 0,
      startedAt: DateTime.tryParse(json['startedAt']?.toString() ?? ''),
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? ''),
      sessionFile: json['sessionFile']?.toString() ?? '',
    );
  }

  int? get contextFree {
    final used = contextTokens;
    final window = contextWindow;
    if (used == null || window == null) return null;
    return (window - used).clamp(0, window);
  }

  String get modelLabel => modelName.isNotEmpty ? modelName : model;

  String get whereLabel => local ? 'локальная (на маке)' : 'по API (удалённая)';
}

class AgentDeleteResult {
  final int deleted;

  final int restored;

  const AgentDeleteResult({this.deleted = 0, this.restored = 0});

  bool get anyDeleted => deleted > 0;

  bool get anyRestored => restored > 0;
}

class AgentActivity {
  final Set<String> running;

  final Set<String> finished;

  final DateTime? updatedAt;

  const AgentActivity({
    this.running = const {},
    this.finished = const {},
    this.updatedAt,
  });

  static const empty = AgentActivity();

  factory AgentActivity.fromJson(Map<String, dynamic> json) {
    Set<String> ids(Object? raw) => <String>{
      if (raw is List)
        for (final item in raw)
          if (item is Map && item['id'] is String) item['id'] as String,
    };
    return AgentActivity(
      running: ids(json['running']),
      finished: ids(json['finished']),
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? ''),
    );
  }
}

class AgentHarness {
  final String harness;

  final String name;

  final bool available;

  final String version;

  const AgentHarness({
    required this.harness,
    this.name = '',
    this.available = false,
    this.version = '',
  });

  factory AgentHarness.fromJson(Map<String, dynamic> json) => AgentHarness(
    harness: json['harness']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    available: json['available'] == true,
    version: json['version']?.toString() ?? '',
  );

  String get label => name.isNotEmpty ? name : harness;
}

class AgentEffort {
  final String id;

  final String name;

  const AgentEffort({required this.id, this.name = ''});

  factory AgentEffort.fromJson(Map<String, dynamic> json) => AgentEffort(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
  );

  String get label => name.isNotEmpty ? name : id;
}

String agentEffortLabel(String id) {
  switch (id.trim()) {
    case 'low':
      return 'низкое';
    case 'medium':
      return 'среднее';
    case 'high':
      return 'высокое';
    case 'xhigh':
      return 'очень высокое';
    case 'max':
      return 'максимальное';
    default:
      return id;
  }
}

class AgentModel {
  final String provider;
  final String id;

  final String name;

  final int? contextWindow;
  final int? maxTokens;

  final bool thinking;

  final bool images;

  final Map<String, Object?> samplingParams;

  final bool local;

  final bool hasKey;

  const AgentModel({
    required this.provider,
    required this.id,
    this.name = '',
    this.contextWindow,
    this.maxTokens,
    this.thinking = false,
    this.images = false,
    this.samplingParams = const {},
    this.local = false,
    this.hasKey = true,
  });

  factory AgentModel.fromJson(Map<String, dynamic> json) => AgentModel(
    provider: json['provider']?.toString() ?? '',
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    contextWindow: json['contextWindow'] is num
        ? (json['contextWindow'] as num).toInt()
        : null,
    maxTokens: json['maxTokens'] is num
        ? (json['maxTokens'] as num).toInt()
        : null,
    thinking: json['thinking'] == true,
    images:
        (json['input'] is List) &&
            ((json['input'] as List).contains('image')) == true,
    samplingParams: <String, Object?>{
      if (json['samplingParams'] is Map)
        for (final e in (json['samplingParams'] as Map).entries)
          '${e.key}': e.value,
    },
    local: json['local'] == true,
    hasKey: json['hasKey'] != false,
  );


  String get key => '$provider/$id';

  String get label => name.isNotEmpty ? name : id;
}

class AgentTool {
  final String id;

  final String name;

  final Map<String, dynamic> args;

  final String output;

  final bool isError;

  final bool running;

  const AgentTool({
    required this.id,
    required this.name,
    this.args = const {},
    this.output = '',
    this.isError = false,
    this.running = false,
  });

  factory AgentTool.fromJson(Map<String, dynamic> json) => AgentTool(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    args: json['args'] is Map
        ? (json['args'] as Map).cast<String, dynamic>()
        : const {},
    output: json['output']?.toString() ?? '',
    isError: json['isError'] == true,
  );

  AgentTool copyWith({
    Map<String, dynamic>? args,
    String? output,
    bool? isError,
    bool? running,
  }) => AgentTool(
    id: id,
    name: name,
    args: args ?? this.args,
    output: output ?? this.output,
    isError: isError ?? this.isError,
    running: running ?? this.running,
  );

  String get summary {
    for (final key in [
      'command',
      'path',
      'file_path',
      'pattern',
      'query',
      'url',
    ]) {
      final value = args[key];
      if (value is String && value.isNotEmpty) return value;
    }
    return args.isEmpty ? '' : args.toString();
  }
}

class AgentBlock {
  final String type;

  final String text;

  final String toolId;

  const AgentBlock({required this.type, this.text = '', this.toolId = ''});

  const AgentBlock.text(String value) : this(type: 'text', text: value);

  const AgentBlock.reasoning(String value)
    : this(type: 'reasoning', text: value);

  const AgentBlock.tool(String id) : this(type: 'tool', toolId: id);

  factory AgentBlock.fromJson(Map<String, dynamic> json) => AgentBlock(
    type: json['type']?.toString() ?? 'text',
    text: json['text']?.toString() ?? '',
    toolId: json['id']?.toString() ?? '',
  );

  bool get isText => type == 'text';

  bool get isReasoning => type == 'reasoning';

  bool get isTool => type == 'tool';

  AgentBlock plus(String extra) =>
      AgentBlock(type: type, text: text + extra, toolId: toolId);
}

class AgentItem {
  final String kind;

  final String text;

  final String reasoning;

  final List<AgentBlock> blocks;

  final List<AgentTool> tools;

  final String error;

  final String command;

  final int? exitCode;

  const AgentItem({
    required this.kind,
    this.text = '',
    this.reasoning = '',
    this.blocks = const [],
    this.tools = const [],
    this.error = '',
    this.command = '',
    this.exitCode,
  });

  factory AgentItem.fromJson(Map<String, dynamic> json) => AgentItem(
    kind: json['kind']?.toString() ?? 'assistant',
    text: json['text']?.toString() ?? '',
    reasoning: json['reasoning']?.toString() ?? '',
    error: json['error']?.toString() ?? '',
    command: json['command']?.toString() ?? '',
    exitCode: json['exitCode'] is int ? json['exitCode'] : null,
    blocks: <AgentBlock>[
      if (json['blocks'] is List)
        for (final b in json['blocks'] as List)
          if (b is Map) AgentBlock.fromJson(b.cast<String, dynamic>()),
    ],
    tools: <AgentTool>[
      if (json['tools'] is List)
        for (final t in json['tools'] as List)
          if (t is Map) AgentTool.fromJson(t.cast<String, dynamic>()),
    ],
  );

  bool get isUser => kind == 'user';

  bool get isAssistant => kind == 'assistant';

  AgentItem copyWith({
    String? text,
    String? reasoning,
    List<AgentBlock>? blocks,
    List<AgentTool>? tools,
    String? error,
    int? exitCode,
  }) => AgentItem(
    kind: kind,
    text: text ?? this.text,
    reasoning: reasoning ?? this.reasoning,
    blocks: blocks ?? this.blocks,
    tools: tools ?? this.tools,
    error: error ?? this.error,
    command: command,
    exitCode: exitCode ?? this.exitCode,
  );

  bool get isEmpty =>
      text.isEmpty && reasoning.isEmpty && tools.isEmpty && blocks.isEmpty;
}

class AgentUsage {
  final int input;
  final int output;

  final int total;

  const AgentUsage({this.input = 0, this.output = 0, this.total = 0});
}

class AgentHealth {
  final String provider;
  final String model;

  final List<String> roots;

  const AgentHealth({
    this.provider = '',
    this.model = '',
    this.roots = const [],
  });

  factory AgentHealth.fromJson(Map<String, dynamic> json) => AgentHealth(
    provider: json['provider']?.toString() ?? '',
    model: json['model']?.toString() ?? '',
    roots: <String>[
      if (json['roots'] is List)
        for (final r in json['roots'] as List) r.toString(),
    ],
  );

  String get label => model;
}

class AgentHistoryPage {
  final List<AgentItem> items;

  final int total;

  final bool hasMore;

  const AgentHistoryPage({
    this.items = const [],
    this.total = 0,
    this.hasMore = false,
  });
}

class AgentEvent {
  final String? text;

  final String? reasoning;

  final String? status;

  final AgentTool? toolStart;

  final AgentTool? toolProgress;

  final AgentTool? toolEnd;

  final AgentTool? toolCall;

  final String? note;

  final int? queued;

  final bool queuedStarted;

  final AgentUsage? usage;

  final AgentSessionInfo? session;

  final bool done;

  final String? error;

  final bool idle;

  final AgentItem? snapshot;

  final bool ping;

  final bool compacted;

  const AgentEvent({
    this.text,
    this.reasoning,
    this.status,
    this.queued,
    this.queuedStarted = false,
    this.toolStart,
    this.toolProgress,
    this.toolEnd,
    this.toolCall,
    this.note,
    this.usage,
    this.session,
    this.done = false,
    this.error,
    this.idle = false,
    this.snapshot,
    this.ping = false,
    this.compacted = false,
  });
}
