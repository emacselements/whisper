# Whisper Vocabulary Guide

## Overview

The vocabulary file helps Whisper recognize difficult proper nouns, technical terms, and specialized vocabulary by providing context hints during transcription.

## Location

Default: `~/.emacs.d/whisper-vocabulary.txt`

To use a different location, add to your `init.el`:
```elisp
(setq whisper-vocabulary-file "/path/to/your/vocabulary.txt")
```

## Format

You can use **any text format** you prefer:

### Option 1: Contextual Sentences (Most Effective)
```
Socrates said that Diotima taught him about love. Alcibiades and Phaedrus joined the Symposium in Athens. Eryximachus was a physician who spoke at the symposium.
```

**Why this works:** Whisper sees the names used naturally in context, making recognition more accurate.

### Option 2: Simple Lists
```
Socrates, Diotima, Alcibiades, Phaedrus, Eryximachus
```

### Option 3: Mixed Format
```
Key figures: Socrates, Diotima, Alcibiades, Phaedrus, Eryximachus

Socrates learned about love from Diotima, a wise woman from Mantinea.
```

## Tips for Better Recognition

1. **Use natural sentences** - Whisper recognizes vocabulary better when proper nouns appear in context rather than simple lists
2. **Place critical words at the end** - The last ~5 words have the most influence on recognition
3. **Stay within limits** - Keep total length under 224 tokens (approximately **150 words maximum**) - anything beyond this limit will be truncated by Whisper
4. **Repeat difficult names** - Use problematic names multiple times in different contexts
5. **Add context** - Place names in natural sentences related to your subject matter
6. **Test and iterate** - If a name is still misrecognized, add more examples with that specific name
7. **Keep it relevant** - Focus on terms you're actually using in your current work

**Word Count Warning:** The package will warn you if your vocabulary file exceeds 150 words when you start recording.

## Examples by Domain

### Classical Philosophy
```
This transcription discusses classical Greek philosophy, including scholars and figures such as Thrasymachus, Eryximachus, Chaerephon, Glaucon, Adeimantus, Socrates, Plato, Diotima, Alcibiades, Phaedrus, Aristophanes, Agathon, Pausanias, and Critias.
```

### Technical/Programming
```
The following is a conversation about software development using tools like Emacs, discussing programming languages, frameworks, and technical terms.
```

### Medical Terminology
```
The patient was diagnosed with arrhythmia and prescribed metoprolol. Echocardiogram showed mitral valve prolapse.
```

## Managing Multiple Vocabularies

For different subjects, create separate vocabulary files:

```elisp
;; In your init.el
(defun use-symposium-vocab ()
  (interactive)
  (setq whisper-vocabulary-file "~/Documents/symposium-vocab.txt")
  (message "Using Symposium vocabulary"))

(defun use-republic-vocab ()
  (interactive)
  (setq whisper-vocabulary-file "~/Documents/republic-vocab.txt")
  (message "Using Republic vocabulary"))
```

Then switch vocabularies as needed with `M-x use-symposium-vocab`.

## Troubleshooting

**Name still not recognized?**
- Add 2-3 more sentences using that specific name
- Verify the spelling in the vocabulary file matches the correct spelling
- Try pronouncing the name more clearly or closer to standard pronunciation

**Transcription seems slower?**
- The vocabulary file may be too large. Keep it focused on current reading/topic (recommended: under 150 words / 224 tokens)

**File not being loaded?**
- Check the file path: The default is `~/.emacs.d/whisper-vocabulary.txt`
- Verify the file exists and has content
- Reload the package after creating/editing the vocabulary file
