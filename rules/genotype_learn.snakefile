"""
Train the model that the genotyper uses to make genotype calls.

The model is trained with a features file equivalent to "samples/NAME/gt_features.tab" (where SAMPLE is the sample
name). The features table can generated by running the genotyper pipeline up to "gt_call_sample_merge" for a sample
that was setup for training (desired features and Illumina sequence data). The "features" configuration option tells
the pipeline where to find this file.

The class labels for each variant are input in another file with one line per variant and in the same order they appear
in the features table. Class labels are "HOM_ALT", "HET", and "HOM_REF". The "labels" configuration option tells the
pipeline where to find this file.

K-fold cross-validation (CV) is performed twice: Once to optimize hyper-parameters (parameters to the model training
method that are not learned by the model), and once to estimate error. These steps are the "tune" and "test"
cross-validation sets. The data is split first for testing (where k-1 sets are used for training, and 1 set is used for
testing). Within the test-training set, the variants are split again into k sets where k-1 sets are used to train the
model with a given set of hyper-parameters and 1 set is used for testing the performance given the hyper-parameters.
The optimal hyper-parameters are chosen, the whole training set is used to train the model, and it is tested against the
held-out fold from the test set. Both cross-validations are iterated over each fold so that each fold has a turn as the
test set.

The whole data set is split again for cross-validation on the whole dataset to learn the hyper-parameters for the final
training set. The optimal set of hyper-parameters is then used to train the final model on all the data. Since this
model cannot be evaluated with held-out data, we use the results of the test cross-validation experiment to estimate it.
"""

import numpy as np
import os
import pandas as pd

from sklearn.externals import joblib
from sklearn.model_selection import GridSearchCV
from sklearn.preprocessing import StandardScaler
from sklearn.svm import SVC

if not 'INCLUDE_SNAKEFILE' in globals():
    include: 'include.snakefile'

from smrtsvlib import ml


##############
### Config ###
##############

with open(config.get('learn_config', 'gt_learn.json'), 'r') as config_in:
    CONFIG_LEARN = json.load(config_in)


####################
### Declarations ###
####################

# Number of cross-validation folds
FOLDS_K = int(CONFIG_LEARN.get('folds', '4'))

# Callable threshold a a sum of depth over ref and alt breakpoints. This is a typical cutoff for choosing NO_CALL
# variants.
CALLABLE_THRESHOLD = int(CONFIG_LEARN.get('callable_threshold', '4'))

# Hyper-parameter grid for grid-search CV
PARAM_GRID = [
    {'kernel': ['rbf'], 'gamma': [1e-1, 5.5e-2, 1e-2, 5.5e-3, 1e-3, 1e-4, 1e-5, 1e-6], 'C': [1, 10, 50, 100, 500, 1000, 5000]}
]

# Get a list of samples and the training sample
FEATURE_SAMPLES = sorted(CONFIG_LEARN.get('features').keys())
FEATURE_SAMPLE_TRAIN = CONFIG_LEARN.get('train_feature')


#############
### Rules ###
#############

localrules: gt_learn, gt_learn_link_stats, gt_learn_model_link_features, gt_learn_model_link_train_array


#
# Evaluate and train
#

# gt_learn
#
# Train predictor and scaler, and get CV stats.
rule gt_learn:
    input:
        predictor='model/predictor.pkl',
        scaler='model/scaler.pkl',
        tab='cv/stats.tab'


#
# Train model
#

# gt_learn_model_train
#
# Train the model that will be used for predictions. Save the whole grid-search CV object, which includes the model.
rule gt_learn_model_train:
    input:
        X_npy='model/X.npy',
        y_npy='model/y.npy',
        feat_tab='model/features.tab'
    output:
        predictor='model/predictor.pkl',
        tab='model/predictor_stats.tab'
    params:
        k=FOLDS_K,
        threads=4
    run:

        # Load data
        X = np.load(input.X_npy)
        y = np.load(input.y_npy)

        features = pd.read_table(input.feat_tab, header=0)

        # Optimize hyper-parameters and fit the best model
        clf = GridSearchCV(
            estimator=SVC(C=1),
            param_grid=PARAM_GRID,
            scoring='accuracy',
            cv=ml.cv_set_iter(ml.stratify_folds(features['STRATIFIED'], params.k)),
            refit=False,
            error_score=0,
            n_jobs=params.threads
        )

        clf.fit(X, y)

        # Train final model
        predictor = SVC(probability=True, **clf.best_params_)
        predictor.fit(X, y)

        # Write model
        joblib.dump(predictor, output.predictor)

        # Write stats
        ml.get_cv_score_table(clf).to_csv(output.tab, sep='\t', index=False)


#
# Test model by statified K-fold cross-validation
#

# gt_learn_link_stats
#
# Link the stats array for the main sample.
rule gt_learn_link_stats:
    input:
        tab=expand('cv/samples/{sample}/stats.tab', sample=FEATURE_SAMPLES)
    output:
        tab='cv/stats.tab'
    shell:
        """ln -sf {FEATURE_SAMPLE_TRAIN}/stats.tab cv/samples/stats.tab"""

# gt_learn_cv_merge_stats
#
# Merge stats
rule gt_learn_cv_merge_stats:
    input:
        tab=expand('cv/samples/{{sample}}/folds/cv_{cv_set}.tab', cv_set=range(FOLDS_K))
    output:
        tab='cv/samples/{sample}/stats.tab'
    run:

        n_folds = len(input.tab)

        # Read tables
        df = pd.read_table(input.tab[0], header=0, index_col='subset')

        # Get stats
        stats = np.asarray(df)  # For first table

        for index in range(1, n_folds):  # For other tables
            stats += np.asarray(pd.read_table(input.tab[index], header=0, index_col='subset'))

        stats /= n_folds

        # Write
        pd.DataFrame(stats, index=df.index, columns=df.columns).to_csv(output.tab, sep='\t')

# gt_learn_cv_run
#
# Run cross-validation to test model performance on the data.
rule gt_learn_cv_run:
    input:
        X_npy='model/X.npy',
        y_npy='model/y.npy',
        scaler='model/scaler.pkl',
        cv_tab='cv/test_sets.tab',
        feat_tab='model/features.tab',
        X_sample=expand('model/samples/{sample}/X.npy', sample=FEATURE_SAMPLES)
    output:
        tab=expand('cv/samples/{sample}/folds/cv_{{cv_set}}.tab', sample=FEATURE_SAMPLES)
    params:
        k=FOLDS_K,
        threads=4
    run:

        cv_set = int(wildcards.cv_set)

        # Load data for model
        X = np.load(input.X_npy)
        y = np.load(input.y_npy)

        scaler = joblib.load(input.scaler)

        fold_array = np.loadtxt(input.cv_tab, np.int32, skiprows=1)

        features = pd.read_table(input.feat_tab, header=0)

        # Load data for samples to CV against
        # sample_list is a list of tuples with one list entry for each sample. The first element of each tuple
        # is the sample name, and the second is the scaled X matrix for that sample.
        sample_list = list()

        for sample in FEATURE_SAMPLES:
            sample_list.append((sample, np.load('model/samples/{}/X.npy'.format(sample))))

        # Get set of callable indices
        callable_set = set(features.index[features['CALLABLE']])

        # Subset data for this fold
        test_indices = fold_array[fold_array[:, 1] == cv_set, 0]
        selection_indices = fold_array[fold_array[:, 1] != cv_set, 0]

        # Subset test indices into variants that would be callable and those that would not be
        test_callable_indices = np.array([x for x in test_indices if x in callable_set])
        test_nocall_indices = np.array([x for x in test_indices if x not in callable_set])

        # Get an array of stratified labels and callable flag for each variant in this fold
        selection_labels = np.asarray(features['STRATIFIED'].loc[selection_indices])

        clf = GridSearchCV(
            estimator=SVC(C=1),
            param_grid=PARAM_GRID,
            scoring='accuracy',
            cv=ml.cv_set_iter(ml.stratify_folds(selection_labels, params.k)),
            refit=True,
            error_score=0,
            n_jobs=params.threads
        )

        clf.fit(X[selection_indices, :], y[selection_indices])

        # Write scores for each sample
        for sample, X_sample in sample_list:
            ml.get_cv_test_scores(
                clf.best_estimator_, X_sample, y,
                test_indices, test_callable_indices, test_nocall_indices
            ).to_csv('cv/samples/{}/folds/cv_{}.tab'.format(sample, wildcards.cv_set), sep='\t', index_label='subset')



# gt_learn_cv_statify_k
#
# Split the variants into k sets stratified over variant type, genotype, and TRF overlap. The modified labels,
# output.labels_tab, are saved for reuse in cross-validation.
rule gt_learn_cv_statify_k:
    input:
        feat_tab='model/features.tab'
    output:
        cv_tab='cv/test_sets.tab'
    params:
        k=FOLDS_K
    run:

        # Read data
        features = pd.read_table(input.feat_tab, header=0)

        # Stratify folds over labels
        fold_array = ml.stratify_folds(features['STRATIFIED'], params.k)

        # Write
        pd.DataFrame(fold_array, columns=('variant', 'test_set')).to_csv(output.cv_tab, sep='\t', index=False)


#
# Model features
#

# gt_learn_model_link_train_array
#
# Get the features
rule gt_learn_model_link_train_array:
    input:
        X_npy='model/samples/{}/X.npy'.format(FEATURE_SAMPLE_TRAIN)
    output:
        X_npy='model/X.npy'
    shell:
        """ln -sf samples/{FEATURE_SAMPLE_TRAIN}/X.npy model/X.npy"""

# gt_learn_model_scale
#
# Scale features.
rule gt_learn_model_scale:
    input:
        tab='model/samples/{sample}/features.tab',
        scaler='model/scaler.pkl'
    output:
        X_npy='model/samples/{sample}/X.npy'
    run:

        # Read
        features = pd.read_table(input.tab, header=0)
        scaler = joblib.load(input.scaler)

        X = ml.features_to_array(features, scaler)

        # Save feature array
        np.save(output.X_npy, X)

# gt_learn_model_scale
#
# Scale features.
rule gt_learn_model_get_scaler:
    input:
        tab='model/features.tab'
    output:
        y_npy='model/y.npy',
        scaler='model/scaler.pkl'
    run:

        # Read
        features = pd.read_table(input.tab, header=0)

        X = ml.features_to_unscaled_matrix(features)
        y = features['CALL'].copy()

        # Fit scaler
        scaler = StandardScaler().fit(X)

        # Save scaler
        joblib.dump(scaler, output.scaler)

        # Save y
        np.save(output.y_npy, y)

# gt_learn_model_link_features
#
# Link the main features table.
rule gt_learn_model_link_features:
    input:
        tab='model/samples/{}/features.tab'.format(FEATURE_SAMPLE_TRAIN)
    output:
        tab='model/features.tab'
    shell:
        """ln -sf samples/{FEATURE_SAMPLE_TRAIN}/features.tab model/features.tab"""

# gt_learn_model_annotate
#
# Merge all training information into one table and annotate.
rule gt_learn_model_annotate:
    input:
        features=lambda wildcards: CONFIG_LEARN['features'][wildcards.sample],
        labels=CONFIG_LEARN['labels']
    output:
        tab='model/samples/{sample}/features.tab'
    params:
        call_thresh=CALLABLE_THRESHOLD
    run:

        # Read features
        df = pd.read_table(input.features, header=0)

        # Read labels
        labels = pd.read_table(input.labels, squeeze=True, header=None)

        if not labels.ndim == 1:
            raise RuntimeError('Labels file {} must contain one column: Found {}'.format(input.labels, labels.ndim))

        if not labels.shape[0] == df.shape[0]:
            raise RuntimeError(
                (
                    """Number of rows in the features table ({}, {} rows) does not match the number of class labels """
                    """({}, {} rows) """
                ).format(input.features, df.shape[0], input.labels, labels.shape[0])
            )

        if any([label not in ml.GT_LABELS for label in labels]):
            raise RuntimeError(
                'Found unrecognized labels in {}: Valid labels are "{}"'.format(input.labels, ', '.join(ml.GT_LABELS))
            )

        # Merge labels (actual calls)
        df['CALL'] = labels

        # Label as callable
        df['CALLABLE'] = df.apply(lambda row: row['REF_COUNT'] + row['ALT_COUNT'] >= params.call_thresh, axis=1)

        # Add statified labels
        # Get feature labels (augmented with TRF annotation for stratification)
        df['STRATIFIED'] = df.apply(
            lambda row: '{}-{}-{}'.format(row['SVTYPE'], row['CALL'], 'CALLABLE' if row['CALLABLE'] else 'NOCALL'),
            axis=1
        )

        # Write
        df.to_csv(output.tab, sep='\t', index=False)
