import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.listing.FunctionManager;

public class MarkLibraryFunctions extends GhidraScript {

	@Override
	protected void run() throws Exception {
		FunctionManager functionManager = getCurrentProgram().getFunctionManager();
		FunctionIterator functions = functionManager.getFunctions(true);

		int totalCount = 0;
		int markedCount = 0;
		int skippedCount = 0;

		while (functions.hasNext()) {
			Function function = functions.next();
			totalCount++;

			if (function.getBody().getNumAddresses() < 6) {
				skippedCount++;
				continue;
			}

			if (!function.isLibraryFunction()) {
				function.setLibraryFunction(true);
				markedCount++;
			}
		}

		printf("MarkLibraryFunctions: %d total, %d marked (≥6 bytes), %d skipped (<6 bytes)%n",
			totalCount, markedCount, skippedCount);
	}
}
