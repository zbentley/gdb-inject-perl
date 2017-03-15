package main

import (
	"fmt"
	log "github.com/Sirupsen/logrus"
	"gopkg.in/alecthomas/kingpin.v2"
	"os"
	"github.com/zbentley/gdb-inject-perl/injector"
	"strings"
	_ "unsafe" // For the signal enumeration trick.
)

func parseArgs(args []string) injector.CodeToInject {
	var (
		app     = kingpin.New("gdb-inject-perl", "Inject code into a running Perl process, using GDB. Dangerous, but useful for getting debug info in a pinch.\nSee https://github.com/zbentley/gdb-inject-perl for more info.").Version("0.1.0")
		pid     = app.Flag("pid", "Process ID of the Perl process to inject code into. PID can be any kind of Perl process: embedded, mod_perl, simple script, etc.\nThis option is required.").Short('p').Required().Int()
		debug   = app.Flag("debug", "Enable (lots of) debug output").Short('d').Bool()
		timeout = app.Flag("timeout", "Time to wait until PID runs CODE. Accepts a duration string, e.g. '10s' or '2m'.\nIf CODE does not run within TIMEOUT, this program will exit with an error unless '--signals' is supplied.\nDefaults to '5s'.").Short('t').Default("5s").Duration()
		code    = app.Flag("code", "String of code that will be injected into the Perl process at PID and run.\nDefaults to a string that prints out the current Perl call stack of the process at PID.").Short('c').Default("require Carp unless exists($INC{'Carp.pm'}); local $Carp::MaxArgLen = 0; local $Carp::MaxArgNums = 0; print $fh Carp::longmess('INJECT')").String()
		force   = app.Flag("force", "Disable validation of CODE via the local Perl interpreter. Not recommended.\nDefaults to false.").Short('f').Bool()
		signals = app.Flag("signals", "If set, enables the sending of signals to stuck Perl processes that will not run CODE.\nThis can cause code to be run even if Perl is stuck in a blocking system call, and should work even in some cases when signals have been blocked by Perl.\nThe user will be prompted on the terminal for a signal to send.\nDefaults to disabled.").Short('s').Default("false").Bool()
		signalmap map[uint32]string
	)
	kingpin.MustParse(app.Parse(args))
	if *pid == os.Getpid() {
		kingpin.Fatalf("Can't run on my own pid")
	}

	if *debug {
		log.SetLevel(log.DebugLevel)
	}

	if *signals {
		signum := uint32(0)
		signalmap = make(map[uint32]string)
		for len(signame(signum)) > 0 {
			words := strings.Fields(signame(signum))
			if words[0] == "signal"  || ! strings.HasPrefix(words[0], "SIG") || strings.ToUpper(words[0]) != words[0] {
				signalmap[signum] = ""
			} else {
				// Remove leading SIG and trailing colon.
				signalmap[signum] = strings.TrimRight(words[0][3:], ":")
			}
			signum++
		}
	}
	codeobj, err := injector.NewCodeToInject(*pid, *code, *timeout, *force, signalmap)
	kingpin.FatalIfError(err, "")

	return codeobj
}

// Sad hack to access a function that is bafflingly not public.
//go:linkname signame runtime.signame
func signame(sig uint32) string

func main() {
	toinject := parseArgs(os.Args[1:])
	defer toinject.Cleanup()
	result, err := toinject.Run()
	fmt.Printf(result)
	kingpin.FatalIfError(err, "")
}
