


//
import Foundation
import Testing
@testable import Tokens

@Suite(.serialized) struct SpeechGapTests {
 @Test static func run() {
  let words = [TimedWord(text:"first",start:0.2,end:1.1,isFinal:true),TimedWord(text:"second",start:3.237,end:4.0,isFinal:true)]
  let gaps = SpeechGapTiming.pauses(words:words,audioEnd:8.583)
  precondition(gaps.count == 2)
  precondition(abs(gaps[0].duration-2.137)<0.000001 && abs(gaps[1].duration-4.583)<0.000001)
  precondition(SpeechGapTiming.pauses(words:words,audioEnd:8.583,includeTrailing:false).count == 1)
  precondition(SpeechGapTiming.pauses(words:[],audioEnd:20).isEmpty)
  precondition(SpeechGapTiming.pauses(words:[words[0],.init(text:"unknown",start:-1,end:-1,isFinal:false),words[1]],audioEnd:8).isEmpty)
  precondition(SpeechGapTiming.pauses(words:words.reversed(),audioEnd:8).isEmpty)
  precondition(SpeechGapTiming.pauses(words:words,audioEnd:1).isEmpty)
  precondition(SpeechGapTiming.live(words:words,audioEnd:4.5,revisionAge:1)==nil)
  precondition(SpeechGapTiming.live(words:words,audioEnd:6,revisionAge:0.1)==nil)
  precondition(SpeechGapTiming.live(words:words,audioEnd:6,revisionAge:1)==2)
  // No callback-arrival interval enters the persisted timestamps.
  precondition(SpeechGapTiming.pauses(words:words,audioEnd:8.583)==gaps)
  let placement=ThinkingComposer.placement(raw:"first second",words:words,pauses:gaps)
  let body=ThinkingComposer.body(placement.segments,unplaced:placement.unplaced){$0}
  let rendered=ThinkingPrompt.format(title:nil,body:body,durationSeconds:8.583,countTranscript:"first second",pauses:gaps.map(\.duration),speechGapEstimate:true)
  precondition(rendered.contains("estimated gaps") && rendered.contains("2x thinking (6.7200s)") && rendered.contains("THINK (2.1370s)"))
  precondition(!rendered.contains("marks measured microphone silence only"))
  let acoustic=ThinkingPrompt.header(title:nil,durationSeconds:8.583,countTranscript:"first second",pauses:[2.137])
  precondition(acoustic.contains(ThinkingPrompt.note))
  print("PASS recognized speech gaps, trailing flush, no missing/reversed timestamp inventions, live settling, and explicit estimated provenance")
 }
}

