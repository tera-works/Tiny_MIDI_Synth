// 本体の音源の対応表（MultiSynth.h の GM_MAP / INSTRUMENTS）と GM の音色名
const List<String> kInst = [
  "Saw Lead", "Acid Bass", "Soft Pad", "Pluck Echo", "Fuzz Lead", "Buzzer Square", "E.Piano", "Organ", "Strings", "Brass",
  "Flute", "Clean Guitar", "Drive Guitar", "Finger Bass", "Synth Bass", "Marimba", "Bell", "Harp", "Drum Kit", "Sax",
  "Piano", "Bright Piano", "Honky-tonk", "Harpsichord", "Clavinet", "Celesta", "Glockenspiel", "Vibraphone", "Xylophone", "Tubular Bells",
  "Perc Organ", "Rock Organ", "Church Organ", "Accordion", "Harmonica", "Nylon Guitar", "Steel Guitar", "Jazz Guitar", "Muted Guitar", "Overdrive Gtr",
  "Gtr Harmonics", "Acoustic Bass", "Pick Bass", "Fretless Bass", "Slap Bass", "Violin", "Cello", "Pizzicato", "Timpani", "Slow Strings",
  "Synth Strings", "Choir Aahs", "Voice Lead", "Orchestra Hit", "Trumpet", "Trombone", "Tuba", "Muted Trumpet", "French Horn", "Synth Brass",
  "Oboe", "Bassoon", "Clarinet", "Square Lead", "Fifths Lead", "Warm Pad", "Poly Synth", "Sweep Pad", "Sitar", "Banjo",
  "Shamisen", "Bagpipe", "Steel Drum", "Woodblock", "Taiko", "Melodic Tom", "Synth Drum", "Reverse Cymbal", "Noise FX", "Noise Hit",
  "Agogo", "Recorder",
];
const List<int> kGmMap = [
  20, 21, 21, 22, 6, 6, 23, 24, 25, 26, 25, 27, 15, 28, 29, 36, 7, 30, 31, 32, 33, 33, 34, 33, 35, 36, 37, 11, 38, 39, 12, 40,
  41, 13, 42, 43, 44, 44, 1, 14, 45, 45, 46, 46, 8, 47, 17, 48, 8, 49, 50, 50, 51, 52, 52, 53, 54, 55, 56, 57, 58, 9, 59, 59,
  19, 19, 19, 19, 60, 60, 61, 62, 10, 10, 81, 10, 10, 10, 81, 81, 63, 0, 81, 10, 4, 52, 64, 0, 2, 65, 66, 51, 65, 67, 51, 67,
  78, 65, 16, 3, 66, 67, 3, 67, 68, 69, 70, 17, 15, 71, 45, 60, 26, 80, 72, 73, 74, 75, 76, 77, 79, 78, 78, 81, 63, 78, 78, 79,
];
const List<String> kGmNames = [
  "Acoustic Grand Piano", "Bright Acoustic Piano", "Electric Grand Piano", "Honky-tonk Piano", "Electric Piano 1", "Electric Piano 2", "Harpsichord", "Clavinet",
  "Celesta", "Glockenspiel", "Music Box", "Vibraphone", "Marimba", "Xylophone", "Tubular Bells", "Dulcimer",
  "Drawbar Organ", "Percussive Organ", "Rock Organ", "Church Organ", "Reed Organ", "Accordion", "Harmonica", "Tango Accordion",
  "Nylon Guitar", "Steel Guitar", "Jazz Guitar", "Clean Guitar", "Muted Guitar", "Overdriven Guitar", "Distortion Guitar", "Guitar Harmonics",
  "Acoustic Bass", "Finger Bass", "Pick Bass", "Fretless Bass", "Slap Bass 1", "Slap Bass 2", "Synth Bass 1", "Synth Bass 2",
  "Violin", "Viola", "Cello", "Contrabass", "Tremolo Strings", "Pizzicato Strings", "Orchestral Harp", "Timpani",
  "String Ensemble 1", "String Ensemble 2", "Synth Strings 1", "Synth Strings 2", "Choir Aahs", "Voice Oohs", "Synth Voice", "Orchestra Hit",
  "Trumpet", "Trombone", "Tuba", "Muted Trumpet", "French Horn", "Brass Section", "Synth Brass 1", "Synth Brass 2",
  "Soprano Sax", "Alto Sax", "Tenor Sax", "Baritone Sax", "Oboe", "English Horn", "Bassoon", "Clarinet",
  "Piccolo", "Flute", "Recorder", "Pan Flute", "Blown Bottle", "Shakuhachi", "Whistle", "Ocarina",
  "Square Lead", "Saw Lead", "Calliope Lead", "Chiff Lead", "Charang Lead", "Voice Lead", "Fifths Lead", "Bass + Lead",
  "New Age Pad", "Warm Pad", "Polysynth Pad", "Choir Pad", "Bowed Pad", "Metallic Pad", "Halo Pad", "Sweep Pad",
  "Rain FX", "Soundtrack FX", "Crystal FX", "Atmosphere FX", "Brightness FX", "Goblins FX", "Echoes FX", "Sci-fi FX",
  "Sitar", "Banjo", "Shamisen", "Koto", "Kalimba", "Bagpipe", "Fiddle", "Shanai",
  "Tinkle Bell", "Agogo", "Steel Drums", "Woodblock", "Taiko Drum", "Melodic Tom", "Synth Drum", "Reverse Cymbal",
  "Guitar Fret Noise", "Breath Noise", "Seashore", "Bird Tweet", "Telephone Ring", "Helicopter", "Applause", "Gunshot",
];
String synthInstName(int prog) => kInst[kGmMap[prog & 127]];
