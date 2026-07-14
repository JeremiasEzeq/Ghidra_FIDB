import ghidra.app.script.GhidraScript;
import ghidra.feature.fid.db.FidFileManager;
import java.io.File;

public class RegisterFidb extends GhidraScript {
	@Override
	protected void run() throws Exception {
		String fidPath = getScriptArgs()[0];
		File f = new File(fidPath);
		if (!f.exists()) {
			println("ERROR: FIDB file not found: " + fidPath);
			return;
		}
		FidFileManager.getInstance().addUserFidFile(f);
		println("Registered FIDB: " + fidPath);
	}
}
