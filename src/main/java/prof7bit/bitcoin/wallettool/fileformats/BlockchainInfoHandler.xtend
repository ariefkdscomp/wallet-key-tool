package prof7bit.bitcoin.wallettool.fileformats

import com.google.bitcoin.core.Base58
import com.google.bitcoin.core.ECKey
import com.google.bitcoin.params.MainNetParams
import com.google.common.base.Charsets
import com.google.common.io.Files
import java.io.File
import java.math.BigInteger
import org.json.JSONException
import org.json.JSONObject
import org.slf4j.Logger
import org.slf4j.LoggerFactory
import org.spongycastle.crypto.InvalidCipherTextException
import org.spongycastle.crypto.PBEParametersGenerator
import org.spongycastle.crypto.engines.AESEngine
import org.spongycastle.crypto.generators.PKCS5S2ParametersGenerator
import org.spongycastle.crypto.modes.CBCBlockCipher
import org.spongycastle.crypto.paddings.ISO10126d2Padding
import org.spongycastle.crypto.paddings.PaddedBufferedBlockCipher
import org.spongycastle.crypto.params.ParametersWithIV
import org.spongycastle.util.encoders.Base64
import prof7bit.bitcoin.wallettool.core.KeyObject
import prof7bit.bitcoin.wallettool.exceptions.FormatFoundNeedPasswordException
import prof7bit.bitcoin.wallettool.exceptions.NeedSecondaryPasswordException

/**
 * Strategy to handle the blockchain.info
 * "My Wallet" backup file format (*.aes.json)
 */
class BlockchainInfoHandler extends AbstractImportExportHandler{
    private static final Logger log = LoggerFactory.getLogger(BlockchainInfoHandler);

    static val AESBlockSize = 16
    static val AESKeySize = 256
    static val DefaultPBKDF2Iterations = 10;

    /**
     * Entry point for the WalletKeyTool import, tries to import the
     * file into the current WalletKeyTool instance.
     * @param file the file to be imported
     * @param pass the password for decryption or null
     * @throws Exception if import fails containing a human readable and comprehensible
     * error message explaining what happened (message string will be presented to the user)
     */
    override load(File file, String pass, String pass2) throws Exception {

        val fileContents = Files.toString(file, Charsets.UTF_8)

        // its either version 1 (entire file is base64 payload)
        // or its version 2 which is a small JSON wrapper around
        // the version 1 payload.
        var String payload
        var int iterations
        try {
            // let's just try version 2 and if this fails to parse...
            val jsonData = new JSONObject(fileContents)
            iterations = jsonData.getInt("pbkdf2_iterations")
            payload = jsonData.getString("payload")
            if (pass == null) {
                // this is definitely the right file format
                // we just need to ask for a password now
                throw new FormatFoundNeedPasswordException
            }
        } catch (JSONException e) {
            // ... then it can only be version 1
            iterations = DefaultPBKDF2Iterations
            payload = fileContents
        }

        if (pass == null){
            throw new Exception("not possible without password")
        }
        val decrypted = decryptWithPass(payload, pass, iterations)
        parseAndImport(decrypted, pass2)
    }

    /**
     * Parse the decrypted JSON wallet and try to add all its keys to the
     * walletKeyTool instance. If the wallet is "double encrypted" which
     * means the keys themselves are encrypted with the secondary password
     * then it will prompt the user for the secondary password.
     * @param jsonStr the plaintext JSON string representing the entire wallet
     * @throws Exception when the data is malformed and import fails or
     * when the wallet has "double encryption" and the second password
     * is wrong.
     */
    private def parseAndImport(String jsonStr, String pass2) throws Exception {
        var int cntImported = 0
        var int cntMissing = 0
        var doubleEnc = false
        var doubleEncIter = DefaultPBKDF2Iterations
        var doubleEncSalt = ""
        val data = new JSONObject(jsonStr)
        if (data.has("double_encryption")){
            if (data.getBoolean("double_encryption")){
                if (pass2 == null){
                    log.info("double encryption, need secondary password")
                    throw new NeedSecondaryPasswordException
                }
                doubleEnc = true
                doubleEncSalt = data.getString("sharedKey")
                doubleEncIter = data.getJSONObject("options").getInt("pbkdf2_iterations")
            }
        }
        val keys = data.getJSONArray("keys")
        var total = keys.length
        var count = 0
        for (i : 0..<total){
            val bciKey = keys.getJSONObject(i)
            var String priv = null
            var ECKey ecKey = null
            val addr = bciKey.getString("addr")
            if (bciKey.has("priv")){
                if (doubleEnc){
                    val doubleEncText = bciKey.getString("priv")
                    priv = decryptWithPass(doubleEncText, doubleEncSalt + pass2, doubleEncIter)
                } else {
                    priv = bciKey.getString("priv")
                }
            }
            if (priv != null){
                ecKey = decodeBase58PK(priv, addr)
                if (bciKey.has("created_time")){
                    ecKey.creationTimeSeconds = bciKey.getLong("created_time")
                }

                // wrap it with our own object and set optional extra info
                val key = new KeyObject(ecKey, walletKeyTool.params)
                if (bciKey.has("label")){
                    key.label = bciKey.getString("label")
                }
                walletKeyTool.add(key)
                cntImported = cntImported + 1
            }else{
                // watch only not implemented
                log.info("skipped {} because it is watch only", addr)
                cntMissing = cntMissing + 1
            }
            walletKeyTool.reportProgress(100 * count / total, addr)
            count = count + 1
        }
        log.info("import complete: {} keys imported, {} skipped because keys were missing",
            cntImported, cntMissing
        )
    }


    override save(File file, String pass, String pass2) throws Exception {
        throw new UnsupportedOperationException("blockchain.info export is not yet implemented")
    }

    /**
     * This is used to remove the outer layer of encryption (the whole file).
     * @param cipherText the base64 encoded text of the backup file
     * @param password needed for decryption, this is the blockchain.info primary password
     * @param iterations the PBKDF2 iterations (10 by default if not otherwise specified)
     * @return decrypted plain text. This would be the JSON string representation of the wallet
     * @throws InvalidCipherTextException if decryption fails
     */
    private def decryptWithPass(String cipherText, String password, int iterations) throws InvalidCipherTextException {
        val cipherdata = Base64.decode(cipherText);

        //Separate the IV and cipher data
        val iv = copyOfRange(cipherdata, 0, AESBlockSize);
        val input = copyOfRange(cipherdata, AESBlockSize, cipherdata.length);

        return decrypt(iv, input, password, iterations)
    }

    /**
     * Decrypt the byte array according to the specifications given by blockchain.info.
     * @param iv initialization vector used to initialize the cipher
     * @param input byte array with encrypted data
     * @param password used to derive the key
     * @param iterations number of PBKDF2 iterations
     * @return String with decrypted plain text
     * @throws InvalidCipherTextException if decryption fails
     */
    private def decrypt(byte[] iv, byte[] input, String password, int iterations) throws InvalidCipherTextException {
        val cipher = createCipher(password, iv, iterations, false)

        // decrypt
        val buf = newByteArrayOfSize(cipher.getOutputSize(input.length))
        var len = cipher.processBytes(input, 0, input.length, buf, 0)
        len = len + cipher.doFinal(buf, len)

        // remove padding
        return new String(buf.take(len), Charsets.UTF_8);
    }

    /**
     * Create and initialize a Cipher object usable to perform the decryption according
     * to blockchain.info's specifications.
     * @param password used to derive the key
     * @param iv initialization vector
     * @param PBKDF2Iterations number of PBKDF2 iterations
     * @param forEncryption shall the cipher be initialized for encryption or decryption
     * @return a newly initialized Cipher object usable to encrypt or decrypt the data from blockchain.info
     */
    private def createCipher(String password, byte[] iv, int PBKDF2Iterations, Boolean forEncryption){
        val passbytes = PBEParametersGenerator.PKCS5PasswordToUTF8Bytes(password.toCharArray())

        val generator = new PKCS5S2ParametersGenerator
        generator.init(passbytes, iv, PBKDF2Iterations)
        val keyParams = new ParametersWithIV(generator.generateDerivedParameters(AESKeySize), iv)

        val cipher = new PaddedBufferedBlockCipher(new CBCBlockCipher(new AESEngine()), new ISO10126d2Padding)
        cipher.init(forEncryption, keyParams)
        return cipher
    }

    private def copyOfRange(byte[] source, int from, int to) {
        val range = newByteArrayOfSize(to - from)
        System.arraycopy(source, from, range, 0, range.length);
        return range;
    }

    /**
     * Try to produce an ECKey Object from the given arguments.
     * BCI has a very uncommon way of encoding the private key, its not the
     * usual dumped private key format of the Satoshi client, its just base58 of
     * the key bytes. Most importantly it is also lacking the information whether
     * it is meant to produce a compressed or uncompressed public key. For this
     * we try both and compare with the supplied bitcoin address, if none of
     * them match (which should never happen) then this will throw an exception.
     *
     * @param base58Priv String containing the BCI encoded private key
     * @param addr String containing the bitcoin address
     * @return a new ECKey object representing this key
     * @throws Exception if the input can not be interpreted in any meaningful way
     */
    private def ECKey decodeBase58PK(String base58Priv, String addr) throws Exception {
        val privBytes = Base58.decode(base58Priv);
        var ecKey = new ECKey(new BigInteger(1, privBytes), null, false);
        if (ecKey.toAddress(new MainNetParams).toString.equals(addr)){
            log.debug("{} has uncompressed key", addr)
            return ecKey;
        } else {
            ecKey = new ECKey(new BigInteger(1, privBytes), null, true);
            if (ecKey.toAddress(new MainNetParams).toString.equals(addr)){
                log.debug("{} has compressed key", addr)
                return ecKey;
            } else {
                val err = addr + " and private key don't match, neither compressed nor uncompressed"
                log.error(err)
                throw new Exception(err)
            }
        }
    }
}
