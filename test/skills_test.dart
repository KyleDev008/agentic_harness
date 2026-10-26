import 'dart:io';

import 'package:agentic_harness/agentic_harness.dart';
import 'package:agentic_harness/io_tools.dart';
import 'package:agentic_harness/testing.dart';
import 'package:test/test.dart';

ToolContext ctx() => ToolContext(
  cancel: CancelToken(),
  runId: 'r',
  toolUseId: 't',
  progress: (_) {},
  requestUserInput: (prompt, {inputType = 'text', choices, fields}) async => '',
  runState: {},
);

final invoices = Skill.withFiles(
  name: 'invoices',
  description: 'Use when writing or checking an invoice.',
  instructions: 'Always include the VAT number.\nSee template.md.',
  files: {'template.md': '# Invoice\nVAT: …'},
);

final refunds = Skill(
  name: 'refunds',
  description: 'Use for refund requests.',
  instructions: 'Refunds over R500 need a manager.',
);

void main() {
  group('Skill', () {
    test('parses SKILL.md front matter', () {
      final skill = Skill.fromMarkdown(
        '---\nname: pdf-forms\ndescription: "Fill in PDF forms."\n'
        'license: MIT\n---\n# PDF forms\n\nStep one.\n',
      );
      expect(skill.name, 'pdf-forms');
      expect(skill.description, 'Fill in PDF forms.');
      expect(skill.instructions, '# PDF forms\n\nStep one.');
      expect(
        () => Skill.fromMarkdown('# no front matter'),
        throwsFormatException,
      );
    });

    test('names and descriptions are validated', () {
      expect(
        () => Skill(name: 'Bad Name', description: 'x', instructions: ''),
        throwsArgumentError,
      );
      expect(
        () => Skill(name: 'ok', description: ' ', instructions: ''),
        throwsArgumentError,
      );
    });
  });

  group('SkillSet', () {
    test(
      'the index lists skills; loading returns instructions and files',
      () async {
        final tools = await SkillSet(skills: [invoices, refunds]).listTools();
        final load = tools.firstWhere((t) => t.name == 'load_skill');
        final read = tools.firstWhere((t) => t.name == 'read_skill_file');
        expect(load.description, contains('- invoices: Use when writing'));
        expect(load.description, contains('- refunds: Use for refund'));

        final loaded = await load.call({'name': 'invoices'}, ctx());
        expect(loaded.text, startsWith('# Skill: invoices'));
        expect(loaded.text, contains('Always include the VAT number.'));
        expect(loaded.text, contains('- template.md'));

        final file = await read.call({
          'skill': 'invoices',
          'path': 'template.md',
        }, ctx());
        expect(file.text, '# Invoice\nVAT: …');

        final missing = await load.call({'name': 'payroll'}, ctx());
        expect(missing.isError, isTrue);
        expect(missing.text, contains('Available: invoices, refunds'));
        final noFile = await read.call({
          'skill': 'invoices',
          'path': '../secrets',
        }, ctx());
        expect(noFile.isError, isTrue);
        // Skills are host content, not the user's private data.
        expect(load.readsPrivateData, isFalse);
      },
    );

    test('the index and content are capped', () async {
      final many = [
        for (var i = 0; i < 50; i++)
          Skill(
            name: 'skill-$i',
            description: 'Description number $i, long enough to add up.',
            instructions: 'x' * 1000,
          ),
      ];
      final set = SkillSet(
        skills: many,
        maxIndexChars: 300,
        maxContentChars: 100,
      );
      final load = (await set.listTools()).first;
      expect(load.description, contains('call load_skill with any name'));
      final out = await load.call({'name': 'skill-49'}, ctx());
      expect(out.text, contains('[… cut at 100 characters …]'));
    });

    test('no skills means no tools', () async {
      expect(await SkillSet().listTools(), isEmpty);
    });

    test('an agent loads a skill and keeps open-world tools', () async {
      final fetch = FunctionTool(
        name: 'fetch',
        description: 'Fetches a page',
        inputSchema: const {'type': 'object'},
        annotations: ToolAnnotations.readOnlyRemote,
        run: (input, _) async => ToolOutput.text('page'),
      );
      final model = FakeModelClient([
        FakeTurn.tools([
          const FakeToolCall('s', 'load_skill', {'name': 'refunds'}),
        ]),
        FakeTurn.tools([const FakeToolCall('f', 'fetch', {})]),
        FakeTurn.text('Needs a manager.'),
      ]);
      final result =
          await const Runner()
              .run(
                AgentSpec(
                  name: 'support',
                  instructions: 'Help customers.',
                  model: model,
                  tools: [fetch],
                  toolProviders: [
                    SkillSet(skills: [invoices, refunds]),
                  ],
                ),
                input: AgentMessage.user('Refund R900 please'),
              )
              .result;
      expect(result.finalText, 'Needs a manager.');
      expect(
        model.lastToolResults(1).single.text,
        contains('Refunds over R500 need a manager.'),
      );
      // Loading a skill doesn't make the standard mode block open-world
      // calls afterwards.
      expect(model.lastToolResults(2).single.text, 'page');
    });
  });

  group('DirectorySkillSource', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('skills_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    void write(String rel, String text) {
      final f = File('${dir.path}/$rel');
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(text);
    }

    test('reads skill folders and their files', () async {
      write(
        'invoices/SKILL.md',
        '---\nname: invoices\ndescription: Invoices.\n---\nUse the template.',
      );
      write('invoices/template.md', 'TEMPLATE');
      write('invoices/.hidden', 'secret');
      write('invoices/data.bin', String.fromCharCodes([0, 1, 2]));
      write('broken/SKILL.md', 'no front matter');
      write('notaskill/readme.md', 'hi');

      final skills = await DirectorySkillSource(dir.path).loadSkills();
      expect(skills.map((s) => s.name), ['invoices']);
      final skill = skills.single;
      expect(skill.instructions, 'Use the template.');
      expect(skill.files, ['data.bin', 'template.md']);
      expect(await skill.readFile('template.md'), 'TEMPLATE');
      await expectLater(
        skill.readFile('data.bin'),
        throwsA(isA<FileSystemException>()),
      );
      expect(() => skill.readFile('.hidden'), throwsArgumentError);
    });

    test('large files are refused', () async {
      write(
        'big/SKILL.md',
        '---\nname: big\ndescription: Big.\n---\nRead huge.txt.',
      );
      write('big/huge.txt', 'x' * 2000);
      final skill =
          (await DirectorySkillSource(
                dir.path,
                maxFileBytes: 1000,
              ).loadSkills())
              .single;
      await expectLater(
        skill.readFile('huge.txt'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('review regressions', () {
    test('front matter: BOM, block values and a missing closer', () {
      final skill = Skill.fromMarkdown(
        '\uFEFF---\nname: notes\ndescription: >\n  Use for notes\n  and memos.\n'
        'extra: |\n  line one\n  line two\n---\nBody\n',
      );
      expect(skill.description, 'Use for notes and memos.');
      expect(skill.instructions, 'Body');
      final (meta, _) = Skill.parseFrontMatter(
        '---\nname: a\nextra: |\n  one\n  two\n---\n',
      );
      expect(meta['extra'], 'one\ntwo');
      expect(
        () => Skill.fromMarkdown('---\nname: a\ndescription: b\nno closer'),
        throwsFormatException,
      );
      // `----` is not a closer.
      expect(
        () => Skill.fromMarkdown('---\nname: a\ndescription: b\n----\nBody'),
        throwsFormatException,
      );
    });

    test(
      'a failing source is retried and does not hide other skills',
      () async {
        final source = _FlakySource();
        final set = SkillSet(skills: [refunds], sources: [source]);
        expect((await set.skills()).keys, ['refunds']);
        expect((await set.skills()).keys, containsAll(['refunds', 'flaky']));
        expect(source.calls, 2);
      },
    );

    test('skills can be marked as private data', () async {
      final tools =
          await SkillSet(
            skills: [refunds],
            containsPrivateData: true,
          ).listTools();
      expect(tools.every((t) => t.readsPrivateData), isTrue);
    });
  });
}

class _FlakySource implements SkillSource {
  int calls = 0;
  @override
  Future<List<Skill>> loadSkills() async {
    if (++calls == 1) throw const FileSystemException('busy');
    return [Skill(name: 'flaky', description: 'Flaky.', instructions: 'x')];
  }
}
