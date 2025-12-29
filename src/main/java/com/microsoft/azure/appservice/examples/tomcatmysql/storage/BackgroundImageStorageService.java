package com.microsoft.azure.appservice.examples.tomcatmysql.storage;

import java.io.InputStream;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

import com.azure.identity.DefaultAzureCredentialBuilder;
import com.azure.storage.blob.BlobClient;
import com.azure.storage.blob.BlobContainerClient;
import com.azure.storage.blob.BlobServiceClient;
import com.azure.storage.blob.BlobServiceClientBuilder;
import com.azure.storage.blob.models.BlobHttpHeaders;
import com.azure.storage.blob.models.BlobStorageException;

/**
 * Handles storage of user background images in Azure Blob Storage.
 */
public class BackgroundImageStorageService {

    private static final Logger logger = LogManager.getLogger(BackgroundImageStorageService.class);
    // Primary env var for the blob service endpoint (e.g., https://<account>.blob.core.windows.net)
    private static final String ENDPOINT_ENV = "BACKGROUND_STORAGE_ENDPOINT";
    // Backward-compatible fallback
    private static final String FALLBACK_ENDPOINT_ENV = "AZURE_STORAGE_BLOB_ENDPOINT";
    private static final String CONTAINER_NAME = "background-images";

    private final BlobContainerClient containerClient;

    public BackgroundImageStorageService() {
        String endpoint = System.getenv(ENDPOINT_ENV);
        if (endpoint == null || endpoint.isBlank()) {
            endpoint = System.getenv(FALLBACK_ENDPOINT_ENV);
        }
        if (endpoint == null || endpoint.isBlank()) {
            throw new IllegalStateException("Environment variable '" + ENDPOINT_ENV + "' (or fallback '" + FALLBACK_ENDPOINT_ENV + "') must be set to the blob service endpoint.");
        }

        BlobServiceClient serviceClient = new BlobServiceClientBuilder()
            .endpoint(endpoint)
            .credential(new DefaultAzureCredentialBuilder().build())
            .buildClient();

        this.containerClient = serviceClient.getBlobContainerClient(CONTAINER_NAME);
        this.containerClient.createIfNotExists();

        logger.info("Background image uploads configured for endpoint {} and container {}", endpoint, CONTAINER_NAME);
    }

    public void uploadBackground(String userId, String extension, String contentType, InputStream data, long length) {
        BlobClient blobClient = containerClient.getBlobClient(userId + extension);
        BlobHttpHeaders headers = new BlobHttpHeaders().setContentType(contentType);
        try {
            blobClient.upload(data, length, true);
            blobClient.setHttpHeaders(headers);
        } catch (BlobStorageException ex) {
            throw new IllegalStateException("Failed to upload background image to blob storage", ex);
        }
    }
}
