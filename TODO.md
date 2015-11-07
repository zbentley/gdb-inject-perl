### TODO:

- CPANify install, with deps.
- Build system:
	- Doctoc for README(s).
	- Automatically pull in latest CONTRIBUTING full copy, rather than using a link.
	- Placeholders for project and script name in readme etc.
	- Deduplication between pod sections and README.
- Documentation:
	- Fix POD external links.
	- Fix README commandline options documentation (separate markdown? pod2html?)
- Interpolation of longmess so as not to need Carp?
- Enable/disable C backtrace.
- Tests.
- Thread support.
- Custom stack-dumping modules (must "can" longmess).
- Execute code from commandline or from file.
- Inject UID into injected string indicating end-of-output.