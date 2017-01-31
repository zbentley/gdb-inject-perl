package main

import (
	"bytes"
	"errors"
	"fmt"
	"github.com/phayes/permbits"
	"gopkg.in/alecthomas/kingpin.v2"
	"io/ioutil"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"bufio"
	log "github.com/Sirupsen/logrus"
)

const (
	DEFAULT_CODE = "require Carp unless exists($INC{'Carp.pm'}); print $fh Carp::longmess('INJECT');"
	TEMPLATE = `{
        local $_;
        local $@;
        local $!;
        local @_;
        local %%SIG = %%SIG;
        local $| = 1;
        if ( open(my $fh, q{>}, q{%s}) ) {
            %s;
            print $fh qq{%s\n};
        }
    };`
)

type CodeToInject struct {
	process os.Process
	code string
	pipe *bufio.Scanner
	tempdir string
	command *exec.Cmd
	timeout time.Duration
}

func CheckPathsForBin(paths ...string) string {
	for _, value := range paths {
		stat, err := permbits.Stat(value)
		if err == nil && stat.UserExecute() {
			return value
		}
	}
	return ""
}

func GetPathForBin(name string, extra ...string) (string, error) {
	returnvalue, err := exec.LookPath(name)
	if err != nil {
		returnvalue = CheckPathsForBin(extra...)
	}
	if returnvalue == "" {
		// Try *really hard* to find the executable
		returnvalue = CheckPathsForBin(
			filepath.Join("/usr/bin", name),
			filepath.Join("/usr/local/bin", name),
			filepath.Join("/bin", name),
			filepath.Join(os.Getenv("HOMEBREW_ROOT"), name),
			filepath.Join(os.Getenv("HOMEBREW_ROOT"), "bin", name),
		)
	}

	if returnvalue == "" {
		err = fmt.Errorf("couldn't find a '%s' executable.", name)
	}
	return returnvalue, err
}

// Try *really hard* to find a world-writable temp dir.
func GetWorldWritableTempDir() (string, error) {
	var (
		dir string
		err error
	)
	if dir, err = ioutil.TempDir("", filepath.Base(os.Args[0])); err != nil {
		if dir, err = filepath.Abs(filepath.Dir(os.Args[0])); err != nil {
			return "", err
		}
	}
	if err = os.Chmod(dir, 0777); err != nil {
		return "", fmt.Errorf("Could not chmod temp directory '%s': %s", dir, err)
	}
	return dir, nil
}

func NewCodeToInject(pid int, code string, timeout time.Duration, force bool) (CodeToInject, error) {
	var (
		returnvalue = CodeToInject{}
		proc, _ = os.FindProcess(pid)
		err error
		gdbpath string
		pipehandle *os.File
	)

	code = strings.TrimSpace(code)
	if ! force {
		if len(code) == 0 {
			return returnvalue, errors.New("contains no data (use --force to override).")
		}
		if strings.IndexByte(code, byte('"')) != -1 {
			return returnvalue, errors.New("double quotation marks are not allowed (use --force to override).")
		}
		if err := test(code); err != nil {
			return returnvalue, fmt.Errorf("Tests failed (use --force to override): %s", err)
		}
	}

	if err = proc.Signal(syscall.Signal(0)); err != nil {
		// Replace() cleans up a confusing error message--more often a proc will
		// be not found than "finished" (whatever that means--nonexistent? Was
		// existent before? Zombied?)
		errorstring := strings.Replace(err.Error(), "already finished", "not found", 1)
		errorstring = strings.Replace(errorstring, "not initialized", "not found", 1)
		return returnvalue, errors.New(fmt.Sprintf("cannot inject to PID %d: %s", pid, errorstring))
	}

	// Make sure we can find GDB
	if gdbpath, err = GetPathForBin("gdb", os.Getenv("GDB")); err != nil {
		return returnvalue, err
	}
	
	// Get a temp directory
	if returnvalue.tempdir, err = GetWorldWritableTempDir(); err != nil {
		return returnvalue, err
	}

	// Create a fifo
	pipepath := filepath.Join(returnvalue.tempdir, "communication_pipe.fifo")
	if err = syscall.Mkfifo(pipepath, 0777); err != nil {
		_ = os.RemoveAll(returnvalue.tempdir)
		return returnvalue, err
	}

	// Open the fifo
	if pipehandle, err = os.OpenFile(pipepath, os.O_RDWR, os.ModeNamedPipe); err != nil {
		_ = os.RemoveAll(returnvalue.tempdir)
		return returnvalue, err
	}

	// Use the current time to make string output a tiny bit more unique.
	terminator := fmt.Sprintf("END %d %d-%d\n", time.Now(), os.Getpid(), proc.Pid)

	// Store a scanner onto the read end of the pipe.
	returnvalue.pipe = bufio.NewScanner(pipehandle)
	returnvalue.pipe.Split(func(data []byte, atEOF bool) (advance int, token []byte, err error) {
        advance, token, err = bufio.ScanLines(data, atEOF)
        if err == nil && token != nil && strings.Contains(string(token), terminator) {
            err = bufio.ErrFinalToken
        }
        return
    })

	code = fmt.Sprintf(TEMPLATE, pipepath, code, terminator)
	code = fmt.Sprintf("call Perl_eval_pv(\"%s\", 0)", code)
	code = strings.Replace(code, "\n", "\\\n", -1)

	returnvalue.command = exec.Command(
		gdbpath,
		"-quiet",
		"-p",
		strconv.Itoa(proc.Pid),
		// Don't ask questions on the command line.
		"-ex", "set confirm off",
		// Pass signals through to Perl without stopping the debugger.
		"-ex", "handle all noprint nostop",
		// Register a pending signal with Perl.
		"-ex", "set variable PL_sig_pending = 1",
		// Stop when we get to the safe-ish signal handler.
		"-ex", "b Perl_despatch_signals",
		// Wait for signalling to happen.
		"-ex", "c",
		"-ex", "delete breakpoints",
		"-ex", code,
		"-ex", "detatch",
		"-ex", "Quit",
	)
	returnvalue.process = *proc
	returnvalue.timeout = timeout
	return returnvalue, nil
}

func (c *CodeToInject) Cleanup() {
	log.Debug("Cleaning up")
	defer os.RemoveAll(c.tempdir)
}

func test(code string) error {
	var (
		inject = fmt.Sprintf(TEMPLATE, "/dev/null", code, strconv.Itoa(os.Getpid()))
		stderr = &bytes.Buffer{}
		file *os.File
		perlpath string
		err error
		command *exec.Cmd
	)
	
	log.Debug("Testing code to inject %s", inject)
	
	if file, err = ioutil.TempFile("", fmt.Sprintf("%s-selftest.pl", path.Base(os.Args[0])) ); err != nil {
		return err
	}
	defer os.Remove(file.Name())

	if err = ioutil.WriteFile(file.Name(), []byte(inject), 0); err != nil {
		return err
	}

	if perlpath, err = GetPathForBin("perl"); err != nil {
		return err
	}
	command = exec.Command(perlpath, "-Mstrict", "-Mwarnings", "-c", file.Name())
	command.Stderr = stderr
	command.Stdout = nil
	err = command.Run()

	if err != nil {
		return fmt.Errorf("%s; stderr: %s", err, stderr.Bytes())
	}
	return nil
}

func parseArgs(args []string) CodeToInject {
	var (
		app = kingpin.New("completion", "My application with bash completion.").Version("0.0.1")
		pid = app.Flag("pid", "ZBTODO timeout").Short('p').Required().Int()
		debug = app.Flag("debug", "ZBTODO timeout").Short('v').Bool()
		timeout = app.Flag("timeout", "ZBTODO timeout").Short('t').Default("5s").Duration()
		code = app.Flag("code", "ZBTODO timeout").Short('c').Default(DEFAULT_CODE).String()
		force = app.Flag("force", "ZBTODO force").Short('f').Bool()
		// signals = app.Flag("signals", "ZBTODO signz").Short('s').Default("true").Bool()
	)
	kingpin.MustParse(app.Parse(args))
	if *pid == os.Getpid() {
		kingpin.Fatalf("Can't run on my own pid")
	}

	if *debug {
		log.SetLevel(log.DebugLevel)
	}
	codeobj, err := NewCodeToInject(*pid, *code, *timeout, *force)
	kingpin.FatalIfError(err, "")

	return codeobj
}

func main() {
	toinject := parseArgs(os.Args[1:])
	defer toinject.Cleanup()
}