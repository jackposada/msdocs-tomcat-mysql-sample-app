package com.microsoft.azure.appservice.examples.tomcatmysql;

import java.io.IOException;
import java.io.OutputStream;
import java.time.OffsetDateTime;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

import com.azure.storage.blob.BlobClient;
import com.azure.storage.blob.models.BlobProperties;
import com.azure.storage.blob.models.BlobStorageException;
import com.microsoft.azure.appservice.examples.tomcatmysql.storage.BackgroundImageStorageService;

import jakarta.servlet.ServletException;
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

@WebServlet(urlPatterns = "/background-image")
public class BackgroundImageServlet extends HttpServlet {

    private static final Logger logger = LogManager.getLogger(BackgroundImageServlet.class);
    private transient BackgroundImageStorageService storageService;

    @Override
    public void init() throws ServletException {
        this.storageService = new BackgroundImageStorageService();
    }

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws ServletException, IOException {
        BlobSelection selection = findLatestBlob();
        if (selection == null) {
            resp.sendError(HttpServletResponse.SC_NOT_FOUND);
            return;
        }

        BlobClient blobClient = selection.client;
        if (blobClient == null) {
            resp.sendError(HttpServletResponse.SC_NOT_FOUND);
            return;
        }

        try {
            BlobProperties props = blobClient.getProperties();
            resp.setContentType(props.getContentType());
            resp.setHeader("Cache-Control", "no-cache, no-store, must-revalidate");
            resp.setHeader("Pragma", "no-cache");
            resp.setDateHeader("Expires", 0);
            try (OutputStream os = resp.getOutputStream()) {
                blobClient.download(os);
            }
        } catch (BlobStorageException ex) {
            logger.warn("Failed to stream background: {}", ex.getMessage());
            resp.sendError(HttpServletResponse.SC_INTERNAL_SERVER_ERROR, "Failed to stream background image");
        }
    }

    private BlobSelection findLatestBlob() {
        BlobSelection selection = null;
        String[] exts = new String[] { ".png", ".jpg" };
        for (String ext : exts) {
            BlobClient blobClient = storageService.getContainerClient().getBlobClient("site-background" + ext);
            if (!blobClient.exists()) {
                continue;
            }
            try {
                OffsetDateTime lm = blobClient.getProperties().getLastModified();
                if (selection == null || (lm != null && selection.lastModified != null && lm.isAfter(selection.lastModified)) || (selection.lastModified == null && lm != null)) {
                    selection = new BlobSelection(blobClient, lm);
                } else if (selection == null) {
                    selection = new BlobSelection(blobClient, lm);
                }
            } catch (BlobStorageException ex) {
                logger.warn("Unable to read properties for {}: {}", blobClient.getBlobName(), ex.getMessage());
                if (selection == null) {
                    selection = new BlobSelection(blobClient, null);
                }
            }
        }
        return selection;
    }

    private static final class BlobSelection {
        final BlobClient client;
        final OffsetDateTime lastModified;

        BlobSelection(BlobClient client, OffsetDateTime lastModified) {
            this.client = client;
            this.lastModified = lastModified;
        }
    }
}
