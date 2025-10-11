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

1. **Repeat difficult names** - Use problematic names multiple times in different contexts
2. **Add context** - Place names in natural sentences related to your subject matter
3. **Test and iterate** - If a name is still misrecognized, add more examples with that specific name
4. **Keep it relevant** - Focus on terms you're actually using in your current work

## Examples by Domain

### Classical Philosophy
```
Socrates said that Diotima taught him about love. Alcibiades and Phaedrus joined the Symposium in Athens. Aristophanes, Agathon, Pausanias, and Eryximachus discussed philosophy.
```

### Technical/Programming
```
Kubernetes orchestrates Docker containers. PostgreSQL database with SQLAlchemy ORM. FastAPI endpoints using Pydantic models.
```

### Medical Terminology
```
The patient was diagnosed with arrhythmia and prescribed metoprolol. Echocardiogram showed mitral valve prolapse.
```

## Managing Multiple Vocabularies

For different subjects, create separate vocabulary files:

```elisp
;; In your init.el
(defun my-use-symposium-vocab ()
  (interactive)
  (setq whisper-vocabulary-file "~/Documents/symposium-vocab.txt")
  (message "Using Symposium vocabulary"))

(defun my-use-republic-vocab ()
  (interactive)
  (setq whisper-vocabulary-file "~/Documents/republic-vocab.txt")
  (message "Using Republic vocabulary"))
```

Then switch vocabularies as needed with `M-x my-use-symposium-vocab`.

## Troubleshooting

**Name still not recognized?**
- Add 2-3 more sentences using that specific name
- Verify the spelling in the vocabulary file matches the correct spelling
- Try pronouncing the name more clearly or closer to standard pronunciation

**Transcription seems slower?**
- The vocabulary file may be too large. Keep it focused on current reading/topic (recommended: under 1000 characters)

**File not being loaded?**
- Check the file path: The default is `~/.emacs.d/whisper-vocabulary.txt`
- Verify the file exists and has content
- Reload the package after creating/editing the vocabulary file
