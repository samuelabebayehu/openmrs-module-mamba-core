package org.openmrs.ohrimamba;

import java.io.IOException;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeoutException;

public class Main {
    public static void main(String[] args) {
        System.out.println("Hello world!");
        ScriptRunner runner = new ScriptRunner();
        try {
            runner.execute();
        } catch (TimeoutException | InterruptedException | ExecutionException | IOException e) {
            System.err.println("Error!");
            e.printStackTrace();
        }
        return;
    }
}