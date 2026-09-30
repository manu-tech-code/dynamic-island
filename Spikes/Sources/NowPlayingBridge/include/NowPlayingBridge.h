#ifndef NOWPLAYINGBRIDGE_H
#define NOWPLAYINGBRIDGE_H

/// Returns a malloc'd UTF-8 JSON object describing what MediaRemote reports
/// right now, as seen from the *calling process*. Caller frees it.
/// Shape: {"ok":bool,"isPlaying":bool|null,"pid":int|null,"info":{...}|null,"elapsedMs":int}
char *np_fetch_json(double timeoutSeconds);

/// Entry point for the perl route. Signature matches a Perl XSUB
/// (PerlInterpreter *, CV *); both arguments are ignored. Reads NP_MODE:
///   "once"        print one JSON line and exit(0)
///   "stream:<s>"  print a JSON line on every change for <s> seconds, then exit(0)
void np_run(void *interp, void *cv);

#endif
