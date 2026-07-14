import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.listing.Program;
import ghidra.program.model.listing.FunctionIterator;
import java.io.PrintWriter;
import java.io.FileWriter;

public class FidbTestReport extends GhidraScript {
	@Override
	protected void run() throws Exception {
		String outputPath = getScriptArgs()[0];

		Program program = getCurrentProgram();
		FunctionManager fm = program.getFunctionManager();

		int totalFuncs = 0;
		int identifiedFuncs = 0;

		FunctionIterator iter = fm.getFunctions(true);
		for (Function func : iter) {
			totalFuncs++;
			if (!func.getName().startsWith("FUN_")) {
				identifiedFuncs++;
			}
		}

		PrintWriter w = new PrintWriter(new FileWriter(outputPath, true));
		w.println("Program: " + program.getName());
		w.println("Functions in program: " + totalFuncs);
		w.println("Functions identified by name: " + identifiedFuncs);
		w.close();

		println("Program: " + program.getName());
		println("Functions in program: " + totalFuncs);
		println("Functions identified by name: " + identifiedFuncs);
	}
}
