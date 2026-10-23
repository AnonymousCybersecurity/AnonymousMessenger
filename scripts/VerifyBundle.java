import java.io.File;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.jar.JarFile;

// Read every payload entry so the JAR verifier detects tampering and unsigned additions.
// No private signing inputs are required and no exception contents are logged.
class VerifyBundle {
    public static void main(String[] args) {
        try (JarFile jar = new JarFile(new File(args[0]), true)) {
            if (jar.getJarEntry("base/manifest/AndroidManifest.xml") == null || jar.getJarEntry("BundleConfig.pb") == null) System.exit(2);
            int verified = 0;
            var entries = jar.entries();
            byte[] buffer = new byte[65536];
            while (entries.hasMoreElements()) {
                var entry = entries.nextElement();
                if (entry.isDirectory()) continue;
                try (var stream = jar.getInputStream(entry)) {
                    while (stream.read(buffer) != -1) { }
                }
                // Only signature infrastructure can be unsigned, not arbitrary META-INF files.
                String name = entry.getName().toUpperCase(java.util.Locale.ROOT);
                if (name.equals("META-INF/MANIFEST.MF") || name.matches("META-INF/[^/]+\\.(SF|RSA|DSA|EC)") || name.startsWith("META-INF/SIG-")) continue;
                var signers = entry.getCodeSigners();
                if (signers == null || signers.length != 1) System.exit(3);
                var certificate = signers[0].getSignerCertPath().getCertificates().get(0);
                String digest = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(certificate.getEncoded()));
                if (!digest.equals(args[1])) System.exit(4);
                verified++;
            }
            if (verified == 0) System.exit(5);
        } catch (Exception error) {
            System.exit(1);
        }
    }
}
