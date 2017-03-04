package injector

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	log "github.com/Sirupsen/logrus"
	"github.com/phayes/permbits"
	"github.com/peterh/liner"
	"io/ioutil"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	TEMPLATE     = `{
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
	pipe    *bufio.Scanner
	tempdir string
	command []string
	timeout time.Duration
	signals map[uint32]string
	reader liner.State
}

func NewCodeToInject(pid int, code string, timeout time.Duration, force bool, signals map[uint32]string) (CodeToInject, error) {
	var (
		returnvalue = CodeToInject{}
		proc, _     = os.FindProcess(pid)
		err         error
		gdbpath     string
		pipehandle  *os.File
	)

	code = strings.TrimSpace(code)
	if !force {
		if len(code) == 0 {
			return returnvalue, errors.New("contains no data (use --force to override).")
		}
		if strings.IndexByte(code, byte('"')) != -1 {
			return returnvalue, errors.New("double quotation marks are not allowed (use --force to override).")
		}
		if err := test(code); err != nil {
			return returnvalue, fmt.Errorf("Tests failed (use --force to override): %s", err)
		} else {
			log.Debug("Tests succeeded")
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

	// Create a fifo. We use a named pipe so we don't have to worry about
	// instances of this proc filling up or writing to a disk etc.
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
	terminator := []byte(fmt.Sprintf("END %d %d-%d", time.Now(), os.Getpid(), proc.Pid))

	// Store a scanner onto the read end of the pipe.
	returnvalue.pipe = bufio.NewScanner(pipehandle)
	returnvalue.pipe.Split(func(data []byte, atEOF bool) (advance int, token []byte, err error) {
		advance, token, err = bufio.ScanLines(data, atEOF)
		if err == nil && bytes.Contains(token, terminator) {
			err = bufio.ErrFinalToken
			token = bytes.Replace(token, terminator, nil, 1)
		}
		return
	})

	perlpath, err := GetPathForBin("perl")

	code = fmt.Sprintf(TEMPLATE, pipepath, code, terminator)
	code = fmt.Sprintf("call Perl_eval_pv(\"%s\", 0)", code)
	code = strings.Replace(code, "\n", "\\\n", -1)
	log.Debug(perlpath)
	returnvalue.command = []string{
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
		//"-ex", "detatch",
		"-ex", "Quit",
	}

	if ( len(signals) ) {
		returnvalue.reader = liner.NewLiner()
		returnvalue.reader.SetCtrlCAborts(true)
		returnvalue.signals = signals

	}

	returnvalue.timeout = timeout
	return returnvalue, nil
}

func (self *CodeToInject) Run() (string, error) {
	var (
		cout = &bytes.Buffer{}
		cerr = &bytes.Buffer{}
		returnvalue = &bytes.Buffer{}
		pipech = make(chan string)
		signalch = make(chan int)
		err  error
		cmd = exec.Command(self.command[0], self.command[1:]...)
		signalsoffered bool
	)

	cmd.Stdout = cout
	cmd.Stderr = cerr

	log.Debugf("Starting command: %s", self.command)
	if err = cmd.Run(); err != nil {
		return "", fmt.Errorf("GDB invocation returned nonzero status: %s", err)
	}

	log.Debugf("GDB invocation STDOUT: %s\n", cout.Bytes())
	log.Debugf("GDB invocation STERR: %s\n", cerr.Bytes())

	go func(ch chan<- string, pipe *bufio.Scanner) {
		for pipe.Scan() {
			ch <- pipe.Text()
		}
	}(pipech, self.pipe)
	timer := time.NewTimer(self.timeout)

	for {
		select {
		case line := <-pipech:
			if len(line) == 0 {
				return returnvalue.String(), self.pipe.Err()
			} else {
				returnvalue.WriteString(line)
				returnvalue.WriteString("\n")
			}
		case signal := <-signalch: {

			if signal < 0 {
				// If user requested cancel, end the timer.
				timer.Reset(0)
			} else {
				if signal > 0 {
					// If it was a real signal, send the kill.
					if  err = cmd.Process.Signal(signal); err != nil {
						// TODO WHAT
					}
				}

				// Even if the user just requested a re-prompt, reset the timer.
				signalsoffered = false
				timer.Reset(self.timeout)
			}
		}
		case <-timer.C:
			if ( ! signalsoffered && len(self.signals) > 0 ) {
				signalsoffered = true
				go self.promptSignals(signalch)
				timer.Reset(self.timeout)
			}
			cmd.Process.Kill() // TODO gentle kill then firm to prevent leaving debug hooks installed
			if returnvalue.Len() == 0 {
				return returnvalue.String(), fmt.Errorf("GDB process timed out. Exit status: %d; code: %s", cmd.ProcessState.String())
			}
		}
	}
}

func (self *CodeToInject) promptSignals(ch chan int) {
	if line, err := self.reader.Prompt("SEND A SIGNAL BRU"); err == nil {
		line = strings.ToUpper(strings.TrimSpace(line));

		if len(line) > 0 {
			// Assumes signums are contiguous. So does the universe.
			if signal, err := strconv.Atoi(line); err == nil && signal < 1 || signal > len(self.signals) {
				ch <- signal
				return
			} else if strings.HasPrefix(line, "SIG") {
				if val, ok := self.signals[line[3:]]; ok {
					ch <- int(val)
					return
				}
			} else if val, ok := self.signals[line]; ok {
				ch <- int(val)
				return
			} else {
				fmt.Printf("Invalid input (no signal found as string or number): '%s'", line)
			}
		}

	} else if err == liner.ErrPromptAborted {
		ch <- -1 // Write the "give up" signal.
	} else {
		log.Error("Error reading line: ", err)
	}
	ch <- 0 // Invalid input
}

func (c *CodeToInject) Cleanup() {
	log.Debug("Cleaning up")
	if ( c.reader != nil ) {
		c.reader.Close()
	}
	defer os.RemoveAll(c.tempdir)
}

func test(code string) error {
	var (
		inject   = fmt.Sprintf(TEMPLATE, "/dev/null", code, strconv.Itoa(os.Getpid()))
		stderr   = &bytes.Buffer{}
		file     *os.File
		perlpath string
		err      error
		command  *exec.Cmd
	)

	log.Debug("Testing code to inject %s", inject)

	if file, err = ioutil.TempFile("", fmt.Sprintf("%s-selftest.pl", path.Base(os.Args[0]))); err != nil {
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
