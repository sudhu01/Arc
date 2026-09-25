import 'package:arc/notes/note_controller.dart';
import 'package:arc/notes/note_doc.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('preserves IME composition through fast successive edits', () {
    final controller = RichNoteController(NoteDoc.empty);
    for (final text in ['h', 'he', 'hel', 'hell', 'hello']) {
      controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
        composing: TextRange(start: 0, end: text.length),
      );
      expect(controller.value.text, text);
      expect(controller.value.composing, TextRange(start: 0, end: text.length));
      expect(controller.doc.text, text);
    }
    controller.dispose();
  });

  test('one backspace removes a word inserted in one keyboard update', () {
    final controller = RichNoteController(NoteDoc('First '));
    controller.value = const TextEditingValue(
      text: 'First workout ',
      selection: TextSelection.collapsed(offset: 14),
    );
    controller.value = const TextEditingValue(
      text: 'First workout',
      selection: TextSelection.collapsed(offset: 13),
    );
    expect(controller.text, 'First ');
    expect(controller.selection.baseOffset, 6);
    controller.dispose();
  });

  test('a committed composing word is removed with one backspace', () {
    final controller = RichNoteController(NoteDoc.empty);
    controller.value = const TextEditingValue(
      text: 'squat',
      selection: TextSelection.collapsed(offset: 5),
      composing: TextRange(start: 0, end: 5),
    );
    controller.value = const TextEditingValue(
      text: 'squat',
      selection: TextSelection.collapsed(offset: 5),
    );
    controller.value = const TextEditingValue(
      text: 'squa',
      selection: TextSelection.collapsed(offset: 4),
    );
    expect(controller.text, isEmpty);
    controller.dispose();
  });

  test('backspace removes an active swipe composition as one word', () {
    final controller = RichNoteController(NoteDoc.empty);
    controller.value = const TextEditingValue(
      text: 'squat',
      selection: TextSelection.collapsed(offset: 5),
      composing: TextRange(start: 0, end: 5),
    );
    controller.value = const TextEditingValue(
      text: 'squa',
      selection: TextSelection.collapsed(offset: 4),
      composing: TextRange(start: 0, end: 4),
    );
    expect(controller.text, isEmpty);
    expect(controller.value.composing, TextRange.empty);
    controller.dispose();
  });

  test('a separately inserted swipe space is removed with its word', () {
    final controller = RichNoteController(NoteDoc.empty);
    controller.value = const TextEditingValue(
      text: 'deadlift',
      selection: TextSelection.collapsed(offset: 8),
    );
    controller.value = const TextEditingValue(
      text: 'deadlift ',
      selection: TextSelection.collapsed(offset: 9),
    );
    controller.value = const TextEditingValue(
      text: 'deadlift',
      selection: TextSelection.collapsed(offset: 8),
    );
    expect(controller.text, isEmpty);
    controller.dispose();
  });

  test('a completed keyboard suggestion replaces its word on backspace', () {
    final controller = RichNoteController(NoteDoc('squ'));
    controller.value = const TextEditingValue(
      text: 'squat',
      selection: TextSelection.collapsed(offset: 5),
    );
    controller.value = const TextEditingValue(
      text: 'squa',
      selection: TextSelection.collapsed(offset: 4),
    );
    expect(controller.text, isEmpty);
    controller.dispose();
  });

  test(
    'ordinary typing and edits after moving the caret stay characterwise',
    () {
      final controller = RichNoteController(NoteDoc.empty);
      controller.value = const TextEditingValue(
        text: 'hello',
        selection: TextSelection.collapsed(offset: 5),
      );
      controller.selection = const TextSelection.collapsed(offset: 2);
      controller.selection = const TextSelection.collapsed(offset: 5);
      controller.value = const TextEditingValue(
        text: 'hell',
        selection: TextSelection.collapsed(offset: 4),
      );
      expect(controller.text, 'hell');
      controller.dispose();
    },
  );
}
