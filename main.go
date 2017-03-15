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
		app     = kingpin.New("completion", "My application with bash completion.").Version("0.0.1")
		pid     = app.Flag("pid", "ZBTODO timeout").Short('p').Required().Int()
		debug   = app.Flag("debug", "ZBTODO timeout").Short('d').Bool()
		timeout = app.Flag("timeout", "ZBTODO timeout").Short('t').Default("5s").Duration()
		code    = app.Flag("code", "ZBTODO timeout").Short('c').Default("require Carp unless exists($INC{'Carp.pm'}); local $Carp::MaxArgLen = 0; local $Carp::MaxArgNums = 0; print $fh Carp::longmess('INJECT')").String()
		force   = app.Flag("force", "ZBTODO force").Short('f').Bool()
		signals = app.Flag("signals", "ZBTODO signz").Short('s').Default("false").Bool()
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
