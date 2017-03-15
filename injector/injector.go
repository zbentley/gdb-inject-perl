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
	"io"
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
	SIGNALHELP = "Type a case-insensitive signal name or number ('sigint', 'INT', and '2' are equivalent), or 'L'/'?' to list available signals."
)

type CodeToInject struct {
	pipe    *bufio.Scanner
	tempdir string
	command *exec.Cmd
	pid int
	timeout time.Duration
	signals map[uint32]string
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

	// Open the fifo. This is done in read/write mode in order to prevent open()
	// from blocking since the writer (the captive process) hasn't connected yet.
	// This process will never write to the pipe.
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
		// Disable "press return to continue"
		"-ex", "set pagination off",
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
	)

	returnvalue.signals = signals
	returnvalue.timeout = timeout
	returnvalue.pid = pid
	return returnvalue, nil
}

func stdStreamProcessor(stderr bool) func(io.Reader, chan<- error) {
	desc := "stdout"
	if stderr {
		desc = "stderr"
	}
	return func(stream io.Reader, errch chan<- error) {
		scanner := bufio.NewScanner(stream)
		for scanner.Scan() {
			line := scanner.Text()
			log.Debugf("GDB %s: %s", desc, line)
			line = strings.ToLower(line) // Don't deal with case in error detection.
			// Known-fatal error strings:
			if stderr {
				if strings.Contains(line, "permission denied") || strings.Contains(line, "operation not permitted") {
					errch<- fmt.Errorf("GDB Failed: %s", line)
					break
				}
			}

		}
		if readerr := scanner.Err(); readerr != nil {
			errch<- fmt.Errorf("Failed while reading GDB's %s: %s; use --debug to see full output", desc, readerr)
		}
	}
}

func (self *CodeToInject) Run() (string, error) {
	var (
		returnvalue = bytes.Buffer{}
		pipech = make(chan string)
		signalch = make(chan int, 1)
		gdbdonech = make(chan error, 1)
		reader *liner.State
	)

	// Start goroutines that will watch lines of stdout/stderr for
	// common conditions that indicate fatal errors, and kill the main
	// polling loop if they occur.
	if outp, err := self.command.StdoutPipe(); err != nil {
		return "", fmt.Errorf("Could not hook up pipe to GDB command stdout: %s", err);
	} else {
		go stdStreamProcessor(false)(outp, gdbdonech)
	}

	if errp, err := self.command.StderrPipe(); err != nil {
		return "", fmt.Errorf("Could not hook up pipe to GDB command stderr: %s", err);
	} else {
		go stdStreamProcessor(true)(errp, gdbdonech)
	}

	log.Debugf("Starting command: %s %v", self.command.Path, self.command.Args)

	if err := self.command.Start(); err != nil {
		return "", fmt.Errorf("GDB invocation returned nonzero status: %s", err)
	} else {
		// TODO gentle kill then firm to prevent leaving debug hooks installed
		defer self.command.Process.Kill()
	}

	// Start a goroutine reading from the pipe, which will (hopefully)
	// soon receive output from the captive process. We can't just slurp
	// all the output from the FIFO once GDB exits or times out, because
	// it's (improbable but) possible that the captive process will be
	// stuck in the midst of a close() operation on the pipe, or will never
	// have opened it in the first place, causing reads to block forever.
	go func(ch chan<- string, pipe *bufio.Scanner) {
		for pipe.Scan() {
			ch <- pipe.Text()
		}
		close(pipech)
	}(pipech, self.pipe)

	// Start a goroutine that will fire the timer/end condition when the GDB command
	// exits. GDB should only exit after the captive process has flushed its write
	// buffers to the FIFO when it calls close() on the named pipe's filehandle upon
	// exiting the if... block in Perl, triggering close-on-destroy.
	go func(kill chan<- error) {
		kill <- self.command.Wait()
	}(gdbdonech)

	timer := time.NewTimer(self.timeout)

	// Run the main multiplexing loop. There are several things being waited for here:
	// 1. The timeout of the main GDB command's execution.
	// 2. Buffered output from the captive process being read from that process's FIFO.
	// 3. Output (and fatal errors) from GDB itself; if fatal errors occur, the loop should stop.
	// 4. User input for signals to send, from the terminal prompting routine.
	// 5. Completion of the main GDB command.
	for {
		select {
		case line := <-pipech:
			if len(line) == 0 {
				// Maybe successful, maybe not:
				gdbdonech <- self.pipe.Err()
			} else {
				returnvalue.WriteString(line)
				returnvalue.WriteString("\n")
				log.Debugf("Got data from captive process: %s\n", line)
			}
		case signal := <-signalch: {
			if signal < 0 {
				// If user requested cancel, end the loop.
				gdbdonech <- errors.New("Interrupted")
			} else if signal > 0 {
				// If it was a real signal, send the kill.
				if err := syscall.Kill(self.pid, syscall.Signal(signal)); err != nil {
					log.Errorf("Failed to send signal to captive process: %s", err)
					signalch <- 0
				} else {
					reader.Close()
					log.Infof("Sent signal %d to captive process (%d)", signal, self.pid)
					timer.Reset(self.timeout) // Stop prompting and wait to see if it wakes up.
				}
			} else { // 0 means "re-prompt"
				if reader == nil {
					// Use a lazy-initialized global object field so we can do a deferred
					// destroy without re-creating a readline terminal each time a user
					// requests a re-prompt.
					reader = liner.NewLiner()
					defer reader.Close()
					reader.SetCtrlCAborts(true)
					fmt.Println("The captive process is not responding. Send a signal to try to wake it up, or press CTRL+C to abort.")
					fmt.Println("WARNING: Waking a process with a signal will almost certainly crash it after debug output is acquired.")
					fmt.Println(SIGNALHELP)
				}
				go self.promptSignals(reader, signalch)
			}
		}
		case <- timer.C:
			if len(self.signals) > 0 {
				signalch <- 0
			} else {
				gdbdonech <- errors.New("GDB process timed out")
			}
		case end := <-gdbdonech:
			return returnvalue.String(), end
		}
	}
}

func printSignals(signals map [uint32]string) {
	l := len(signals)
	// Roughly approximate the output of "kill -l"
	for i := 1; i < l; i += 5 {
		for j := i; j < i + 5 && j < l; j++ {
			signame := signals[uint32(j)]
			if len(signame) == 0 {
				signame = "[unknown]"
			} else {
				signame = "SIG" + signame
			}
			fmt.Printf("%2d) %-16s", j, signame)
		}
		fmt.Print("\n")
	}
}

func (self *CodeToInject) promptSignals(reader *liner.State, ch chan<- int) {
	for {
		if line, err := reader.Prompt("Signal name, number, 'L' or '?': "); err == nil {
			line = strings.ToUpper(strings.TrimSpace(line));

			if len(line) > 0 {
				// Assumes signums are contiguous. So does the universe.
				if line == "L" || line == "?" {
					printSignals(self.signals)
					continue
				} else if signal, err := strconv.Atoi(line); err == nil && signal > 1 && signal <= len(self.signals) {
					ch <- signal
					return
				} else {
					for k, v := range self.signals {
						if ( strings.HasPrefix(line, "SIG") && v == line[3:] ) || v == line {
							ch <- int(k)
							return
						}
					}
				}
				fmt.Printf("Invalid input (no signal found as string or number): '%s'\n%s\n", line, SIGNALHELP)
			}
		} else if err == liner.ErrPromptAborted {
			ch <- -1 // Write the "give up" signal.
		} else {
			log.Errorf("Error reading line: %s\n", err)
		}
	}
}

func (c *CodeToInject) Cleanup() {
	log.Debug("Cleaning up")
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
			// OSX specific stuff. Probably a waste, since the dylib version on that system won't work with GDB as of this writing.
			//filepath.Join(os.Getenv("HOMEBREW_ROOT"), name),
			//filepath.Join(os.Getenv("HOMEBREW_ROOT"), "bin", name),
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
