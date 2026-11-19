// SwiftPM needs a source file in a C target; PDFium itself is linked as a library.
int cpdfium_module_present(void) { return 1; }
